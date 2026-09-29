// Elimina la cuenta de quien la pide (exigido por App Store y Google Play).
// Anonimiza los datos, borra documentos privados y elimina el acceso (Auth).
import { corsHeaders, handleError, json, PublicError } from '../_shared/http.ts';
import { adminClient, requireUser } from '../_shared/supabase.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new PublicError('Método no permitido', 405);
    const userId = await requireUser(req);
    const db = adminClient();

    const { data: result, error } = await db.rpc('delete_account_data', { p_user_id: userId });
    if (error) throw error;
    if (result === 'active_bookings') {
      throw new PublicError('Tienes reservas pagadas o en curso. Podrás eliminar tu cuenta cuando terminen.', 409);
    }

    // Documentos privados (licencia, cédula)
    const { data: files, error: listErr } = await db.storage.from('documents').list(userId, { limit: 1000 });
    if (listErr) throw listErr;
    if (files && files.length > 0) {
      const { error: rmErr } = await db.storage.from('documents').remove(files.map((f) => `${userId}/${f.name}`));
      if (rmErr) throw rmErr;
    }

    // Borrado suave: el acceso desaparece y se conserva el historial contable anonimizado.
    const { error: delErr } = await db.auth.admin.deleteUser(userId, true);
    if (delErr) throw delErr;

    return json({ ok: true });
  } catch (err) {
    return handleError('delete-account', err);
  }
});
