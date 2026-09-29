// Envía una notificación push (Expo Push API) para un aviso recién creado.
// La llama la base de datos (trigger dispatch_push) con un secreto interno.
import { handleError, json } from '../_shared/http.ts';
import { adminClient, setting } from '../_shared/supabase.ts';

type ExpoTicket = { status: 'ok' | 'error'; details?: { error?: string } };

Deno.serve(async (req) => {
  try {
    if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);
    const db = adminClient();
    const expected = await setting(db, 'internal_webhook_secret');
    if (!expected || req.headers.get('x-rue-secret') !== expected) return json({ error: 'no autorizado' }, 401);

    const { notification_id: id } = (await req.json()) as { notification_id?: string };
    if (!id) return json({ error: 'falta notification_id' }, 400);

    const { data: n, error } = await db
      .from('notifications')
      .select('id, user_id, title, body, booking_id, pushed_at')
      .eq('id', id)
      .maybeSingle();
    if (error) throw error;
    if (!n || n.pushed_at) return json({ ok: true, skipped: true });

    const { data: tokens, error: tErr } = await db.from('push_tokens').select('token').eq('user_id', n.user_id);
    if (tErr) throw tErr;

    if (tokens && tokens.length > 0) {
      const messages = tokens.map((t) => ({
        to: t.token,
        title: n.title,
        body: n.body,
        sound: 'default',
        data: n.booking_id ? { booking_id: n.booking_id } : {},
      }));
      const res = await fetch('https://exp.host/--/api/v2/push/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(messages),
      });
      if (!res.ok) throw new Error(`Expo Push respondió ${res.status}`);
      const { data: tickets } = (await res.json()) as { data: ExpoTicket[] };
      const dead = tickets
        .map((t, i) => (t.status === 'error' && t.details?.error === 'DeviceNotRegistered' ? tokens[i].token : null))
        .filter((t): t is string => t !== null);
      if (dead.length > 0) {
        const { error: delErr } = await db.from('push_tokens').delete().in('token', dead);
        if (delErr) console.error('[push-dispatch] no se pudieron borrar tokens vencidos', delErr.message);
      }
    }

    const { error: updErr } = await db.from('notifications').update({ pushed_at: new Date().toISOString() }).eq('id', n.id);
    if (updErr) throw updErr;
    return json({ ok: true, sent: tokens?.length ?? 0 });
  } catch (err) {
    return handleError('push-dispatch', err);
  }
});
