// Crea (o reutiliza) el link de pago de Mercado Pago para una reserva aceptada.
// El monto sale SIEMPRE de la reserva en la base de datos, nunca de la app.
import { corsHeaders, handleError, json, PublicError, requireEnv } from '../_shared/http.ts';
import { createPreference, mpEnvironment } from '../_shared/mercadopago.ts';
import { isAllowedAppRedirect } from '../_shared/redirect.ts';
import { adminClient, requireUser } from '../_shared/supabase.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new PublicError('Método no permitido', 405);
    const userId = await requireUser(req);
    const { booking_id: bookingId, redirect_url: redirectUrl } = (await req.json()) as {
      booking_id?: string;
      redirect_url?: string;
    };
    if (!bookingId) throw new PublicError('Falta la reserva');
    if (!isAllowedAppRedirect(redirectUrl ?? null)) throw new PublicError('Link de retorno no válido');

    const db = adminClient();
    const { data: booking, error } = await db
      .from('bookings')
      .select('id, renter_id, status, total_clp, expires_at, vehicle:vehicles(title)')
      .eq('id', bookingId)
      .maybeSingle();
    if (error) throw error;
    if (!booking || booking.renter_id !== userId) throw new PublicError('Reserva no encontrada', 404);
    if (booking.status !== 'aceptada') throw new PublicError('Esta reserva ya no está esperando pago', 409);
    if (booking.expires_at && new Date(booking.expires_at) < new Date()) {
      throw new PublicError('Se venció el plazo para pagar esta reserva', 409);
    }
    if (booking.total_clp <= 0) throw new PublicError('El monto de la reserva no es válido', 409);

    const environment = mpEnvironment();
    const base = requireEnv('SUPABASE_URL');
    const returnUrl = `${base}/functions/v1/mp-return?booking=${encodeURIComponent(bookingId)}&redirect=${encodeURIComponent(redirectUrl as string)}`;

    // Reutiliza la preferencia ya creada para este monto (evita duplicados).
    const { data: existing } = await db
      .from('payments')
      .select('id, checkout_url, amount_clp')
      .eq('booking_id', bookingId)
      .eq('status', 'created')
      .eq('environment', environment)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (existing?.checkout_url && existing.amount_clp === booking.total_clp) {
      return json({ checkout_url: existing.checkout_url });
    }

    const { data: user } = await db.auth.admin.getUserById(userId);
    const vehicle = booking.vehicle as unknown as { title: string } | null;
    const pref = await createPreference(requireEnv('MP_ACCESS_TOKEN'), {
      bookingId,
      title: `Arriendo RUÉ · ${vehicle?.title ?? 'vehículo'}`,
      amountClp: booking.total_clp,
      payerEmail: user?.user?.email ?? null,
      notificationUrl: `${base}/functions/v1/mp-webhook`,
      returnUrl,
      expiresAt: booking.expires_at ? new Date(booking.expires_at) : new Date(Date.now() + 24 * 3600 * 1000),
    });

    const { error: insErr } = await db.from('payments').insert({
      booking_id: bookingId,
      environment,
      preference_id: pref.id,
      status: 'created',
      amount_clp: booking.total_clp,
      checkout_url: pref.init_point,
    });
    if (insErr) throw insErr;

    return json({ checkout_url: pref.init_point });
  } catch (err) {
    return handleError('mp-create-preference', err);
  }
});
