// Crea la transacción de Webpay Plus para una reserva aceptada o una extensión aprobada.
// El monto sale SIEMPRE de la base de datos, nunca de la app.
import { corsHeaders, handleError, json, PublicError, requireEnv } from '../_shared/http.ts';
import { isAllowedAppRedirect } from '../_shared/redirect.ts';
import { adminClient, requireUser } from '../_shared/supabase.ts';
import { createTransaction, newBuyOrder, webpayConfig } from '../_shared/webpay.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new PublicError('Método no permitido', 405);
    const userId = await requireUser(req);
    const {
      booking_id: bookingId,
      extension_id: extensionId,
      redirect_url: redirectUrl,
    } = (await req.json()) as { booking_id?: string; extension_id?: string; redirect_url?: string };
    if (!bookingId) throw new PublicError('Falta la reserva');
    if (!isAllowedAppRedirect(redirectUrl ?? null)) throw new PublicError('Link de retorno no válido');

    const db = adminClient();
    const { data: booking, error } = await db
      .from('bookings')
      .select('id, renter_id, status, total_clp, expires_at')
      .eq('id', bookingId)
      .maybeSingle();
    if (error) throw error;
    if (!booking || booking.renter_id !== userId) throw new PublicError('Reserva no encontrada', 404);

    let amount: number;
    if (extensionId) {
      const { data: ext, error: extErr } = await db
        .from('booking_extensions')
        .select('id, booking_id, status, total_clp, expires_at')
        .eq('id', extensionId)
        .maybeSingle();
      if (extErr) throw extErr;
      if (!ext || ext.booking_id !== bookingId) throw new PublicError('Extensión no encontrada', 404);
      if (ext.status !== 'awaiting_payment') throw new PublicError('Esta extensión no está esperando pago', 409);
      if (ext.expires_at && new Date(ext.expires_at) < new Date()) {
        throw new PublicError('Se venció el plazo para pagar esta extensión', 409);
      }
      amount = ext.total_clp;
    } else {
      if (booking.status !== 'aceptada') throw new PublicError('Esta reserva ya no está esperando pago', 409);
      if (booking.expires_at && new Date(booking.expires_at) < new Date()) {
        throw new PublicError('Se venció el plazo para pagar esta reserva', 409);
      }
      amount = booking.total_clp;
    }
    if (amount < 50) throw new PublicError('El monto no es válido', 409);

    const cfg = webpayConfig();
    const returnUrl = `${requireEnv('SUPABASE_URL')}/functions/v1/webpay-return?r=${encodeURIComponent(redirectUrl as string)}`;
    if (returnUrl.length > 256) throw new PublicError('Link de retorno demasiado largo');

    const buyOrder = newBuyOrder();
    const tx = await createTransaction(cfg, { buyOrder, sessionId: extensionId ?? bookingId, amount, returnUrl });

    const { error: insErr } = await db.from('payments').insert({
      booking_id: bookingId,
      extension_id: extensionId ?? null,
      provider: 'webpay',
      environment: cfg.environment,
      preference_id: tx.token,
      buy_order: buyOrder,
      status: 'created',
      amount_clp: amount,
      checkout_url: `${tx.url}?token_ws=${encodeURIComponent(tx.token)}`,
    });
    if (insErr) throw insErr;

    return json({ checkout_url: `${tx.url}?token_ws=${encodeURIComponent(tx.token)}` });
  } catch (err) {
    return handleError('webpay-create', err);
  }
});
