// Webhook de Mercado Pago. Única vía para confirmar una reserva pagada.
// 1) Verifica la firma. 2) Guarda el evento (idempotencia). 3) Consulta el pago a la API de MP.
// 4) Confirma la reserva con confirm_booking_payment() (idempotente) o registra el estado.
import { handleError, json, requireEnv } from '../_shared/http.ts';
import { getPayment, mpEnvironment, verifyMpSignature } from '../_shared/mercadopago.ts';
import { adminClient } from '../_shared/supabase.ts';

Deno.serve(async (req) => {
  try {
    if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);
    const url = new URL(req.url);
    const bodyText = await req.text();
    let body: { type?: string; action?: string; data?: { id?: string | number } } = {};
    try {
      body = bodyText ? JSON.parse(bodyText) : {};
    } catch {
      console.warn('[mp-webhook] cuerpo no es JSON');
    }

    const type = url.searchParams.get('type') ?? body.type ?? url.searchParams.get('topic');
    const dataId = url.searchParams.get('data.id') ?? (body.data?.id !== undefined ? String(body.data.id) : null);

    const valid = await verifyMpSignature({
      secret: requireEnv('MP_WEBHOOK_SECRET'),
      signatureHeader: req.headers.get('x-signature'),
      requestId: req.headers.get('x-request-id'),
      dataId,
      maxAgeSeconds: 60 * 60 * 24,
    });
    if (!valid) {
      console.warn('[mp-webhook] firma inválida');
      return json({ error: 'firma inválida' }, 401);
    }

    // Solo nos interesan los pagos.
    if (type !== 'payment' || !dataId) return json({ ok: true, ignored: true });

    const db = adminClient();
    const eventKey = `${type}:${dataId}:${req.headers.get('x-request-id') ?? body.action ?? ''}`;
    const { error: evErr } = await db
      .from('payment_events')
      .insert({ provider: 'mercadopago', event_key: eventKey, payload: body });
    if (evErr && evErr.code !== '23505') throw evErr; // 23505 = evento repetido: se procesa igual (idempotente)

    const payment = await getPayment(requireEnv('MP_ACCESS_TOKEN'), dataId);
    if (!payment) {
      await markEvent(db, eventKey, 'pago no encontrado en Mercado Pago');
      return json({ ok: true });
    }

    const environment = mpEnvironment();
    if ((environment === 'prod') !== payment.live_mode) {
      await markEvent(db, eventKey, `ambiente distinto (live_mode=${payment.live_mode})`);
      return json({ ok: true, ignored: true });
    }

    const bookingId = payment.external_reference;
    if (!bookingId || payment.currency_id !== 'CLP') {
      await markEvent(db, eventKey, 'pago sin reserva asociada o moneda distinta de CLP');
      return json({ ok: true, ignored: true });
    }
    const amount = Math.round(payment.transaction_amount);

    if (payment.status === 'approved') {
      const { data: result, error } = await db.rpc('confirm_booking_payment', {
        p_booking_id: bookingId,
        p_provider_payment_id: String(payment.id),
        p_amount_clp: amount,
        p_environment: environment,
      });
      if (error) throw error;
      if (result === 'amount_mismatch' || result === 'not_payable') {
        // Requiere revisión manual (y posiblemente reembolso). Queda registrado.
        console.error(`[mp-webhook] pago ${payment.id} de la reserva ${bookingId}: ${result}`);
      }
      await markEvent(db, eventKey, result === 'confirmed' || result === 'already_confirmed' ? null : String(result));
    } else {
      const { error } = await db.rpc('record_payment_status', {
        p_booking_id: bookingId,
        p_provider_payment_id: String(payment.id),
        p_status: payment.status,
        p_status_detail: payment.status_detail,
        p_amount_clp: amount,
        p_environment: environment,
      });
      if (error) throw error;
      await markEvent(db, eventKey, null);
    }

    return json({ ok: true });
  } catch (err) {
    // 500 → Mercado Pago reintenta más tarde.
    return handleError('mp-webhook', err);
  }
});

async function markEvent(db: ReturnType<typeof adminClient>, eventKey: string, error: string | null) {
  const { error: updErr } = await db
    .from('payment_events')
    .update({ processed_at: new Date().toISOString(), error })
    .eq('provider', 'mercadopago')
    .eq('event_key', eventKey);
  if (updErr) console.error('[mp-webhook] no se pudo marcar el evento', updErr.message);
}
