// Transbank devuelve a la persona aquí después del formulario de Webpay.
// Aquí el SERVIDOR confirma la transacción (commit) y, solo si está aprobada y
// el monto coincide, confirma la reserva. Si la reserva ya no se podía pagar,
// anula el cargo automáticamente. Después redirige a la app.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

import { isAllowedAppRedirect } from '../_shared/redirect.ts';
import { adminClient } from '../_shared/supabase.ts';
import {
  commitTransaction,
  decideOutcome,
  getTransaction,
  readReturnParams,
  refundTransaction,
  TbkError,
  webpayConfig,
  type TbkTransaction,
  type WebpayConfig,
} from '../_shared/webpay.ts';

type AppStatus = 'approved' | 'rejected' | 'cancelled' | 'refunded' | 'error';

function backToApp(redirect: string | null, status: AppStatus, bookingId: string | null): Response {
  if (!isAllowedAppRedirect(redirect)) {
    return new Response('Vuelve a la app RUÉ para ver el estado de tu reserva.', {
      status: 200,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
  const sep = redirect.includes('?') ? '&' : '?';
  const target = `${redirect}${sep}status=${status}${bookingId ? `&booking=${encodeURIComponent(bookingId)}` : ''}`;
  return new Response(null, { status: 302, headers: { Location: target } });
}

/** Confirma en Transbank; si el commit falla (por ejemplo, ya confirmado), consulta el estado. */
async function commitOrStatus(cfg: WebpayConfig, token: string): Promise<TbkTransaction> {
  try {
    return await commitTransaction(cfg, token);
  } catch (err) {
    console.warn('[webpay-return] commit falló, consultando estado:', err instanceof Error ? err.message : String(err));
    if (err instanceof TbkError && err.status >= 500) throw err;
    return await getTransaction(cfg, token);
  }
}

async function logEvent(db: SupabaseClient, key: string, tx: TbkTransaction | null, error: string | null) {
  // Sin datos de tarjeta: solo campos del resultado.
  const payload = tx
    ? {
        status: tx.status,
        response_code: tx.response_code,
        amount: tx.amount,
        buy_order: tx.buy_order,
        payment_type_code: tx.payment_type_code,
        installments_number: tx.installments_number,
        authorization_code: tx.authorization_code,
      }
    : {};
  const { error: e } = await db.from('payment_events').upsert(
    { provider: 'webpay', event_key: key, payload, processed_at: new Date().toISOString(), error },
    { onConflict: 'provider,event_key' },
  );
  if (e) console.error('[webpay-return] no se pudo registrar el evento', e.message);
}

Deno.serve(async (req) => {
  const redirect = new URL(req.url).searchParams.get('r');
  let bookingId: string | null = null;
  try {
    const params = await readReturnParams(req);
    const db = adminClient();
    const cfg = webpayConfig();

    // La persona anuló el pago o se agotó el tiempo del formulario.
    if (!params.token) {
      const aborted = params.abortedToken;
      if (aborted) {
        const { data } = await db
          .from('payments')
          .update({ status: 'aborted' })
          .eq('provider', 'webpay')
          .eq('preference_id', aborted)
          .eq('status', 'created')
          .select('booking_id')
          .maybeSingle();
        bookingId = data?.booking_id ?? null;
      }
      return backToApp(redirect, 'cancelled', bookingId);
    }

    const { data: payment, error } = await db
      .from('payments')
      .select('id, booking_id, amount_clp, buy_order, environment, status')
      .eq('provider', 'webpay')
      .eq('preference_id', params.token)
      .maybeSingle();
    if (error) throw error;
    if (!payment) {
      console.warn('[webpay-return] token desconocido');
      return backToApp(redirect, 'error', null);
    }
    bookingId = payment.booking_id;

    const tx = await commitOrStatus(cfg, params.token);
    const outcome = decideOutcome(tx, payment.amount_clp, payment.buy_order);

    const { error: updErr } = await db
      .from('payments')
      .update({
        provider_payment_id: payment.buy_order,
        status: outcome === 'approved' ? 'approved' : outcome === 'rejected' ? 'rejected' : 'review',
        status_detail: `response_code=${tx.response_code ?? 'n/a'} status=${tx.status}`,
        payment_type: tx.payment_type_code ?? null,
        installments: tx.installments_number ?? null,
      })
      .eq('id', payment.id);
    if (updErr) throw updErr;

    if (outcome === 'rejected') {
      const { error: e } = await db.rpc('record_payment_status', {
        p_booking_id: payment.booking_id,
        p_provider_payment_id: payment.buy_order,
        p_status: 'rejected',
        p_status_detail: `response_code=${tx.response_code ?? 'n/a'}`,
        p_amount_clp: payment.amount_clp,
        p_environment: payment.environment,
        p_provider: 'webpay',
      });
      if (e) throw e;
      await logEvent(db, `commit:${params.token}`, tx, null);
      return backToApp(redirect, 'rejected', bookingId);
    }

    let result: string = 'amount_mismatch';
    if (outcome === 'approved') {
      const { data, error: e } = await db.rpc('confirm_booking_payment', {
        p_booking_id: payment.booking_id,
        p_provider_payment_id: payment.buy_order,
        p_amount_clp: payment.amount_clp,
        p_environment: payment.environment,
        p_provider: 'webpay',
      });
      if (e) throw e;
      result = String(data);
    }

    if (result === 'already_confirmed') {
      // ¿La reserva ya estaba pagada con OTRA transacción? Entonces este es un pago doble y se anula.
      const { data: others, error: oErr } = await db
        .from('payments')
        .select('id')
        .eq('booking_id', payment.booking_id)
        .eq('status', 'approved')
        .neq('id', payment.id)
        .limit(1);
      if (oErr) throw oErr;
      result = others && others.length > 0 ? 'double_payment' : 'already_confirmed';
    }

    if (result === 'confirmed' || result === 'already_confirmed') {
      await logEvent(db, `commit:${params.token}`, tx, null);
      return backToApp(redirect, 'approved', bookingId);
    }

    // Pagó algo que no corresponde (reserva vencida/cancelada o monto distinto): se anula el cargo.
    try {
      await refundTransaction(cfg, params.token, Math.round(tx.amount));
      const { error: e } = await db.rpc('record_payment_status', {
        p_booking_id: payment.booking_id,
        p_provider_payment_id: payment.buy_order,
        p_status: 'refunded',
        p_status_detail: `anulado automáticamente: ${result}`,
        p_amount_clp: payment.amount_clp,
        p_environment: payment.environment,
        p_provider: 'webpay',
      });
      if (e) throw e;
      await logEvent(db, `commit:${params.token}`, tx, result);
      return backToApp(redirect, 'refunded', bookingId);
    } catch (refundErr) {
      // No se pudo anular: queda para revisión manual (OPERACION.md).
      console.error('[webpay-return] no se pudo anular el cargo', refundErr instanceof Error ? refundErr.message : String(refundErr));
      await logEvent(db, `commit:${params.token}`, tx, `${result}; anulación pendiente`);
      return backToApp(redirect, 'error', bookingId);
    }
  } catch (err) {
    console.error('[webpay-return]', err instanceof Error ? err.message : String(err));
    return backToApp(redirect, 'error', bookingId);
  }
});
