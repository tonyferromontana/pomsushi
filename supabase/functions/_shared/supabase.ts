import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

import { PublicError, requireEnv } from './http.ts';

/** Cliente con service role: salta RLS. Úsalo solo después de validar permisos. */
export function adminClient(): SupabaseClient {
  return createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Devuelve el id del usuario dueño del JWT de la petición, o lanza 401. */
export async function requireUser(req: Request): Promise<string> {
  const auth = req.headers.get('Authorization');
  if (!auth?.startsWith('Bearer ')) throw new PublicError('Tienes que iniciar sesión', 401);
  const client = createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new PublicError('Tu sesión expiró. Vuelve a entrar.', 401);
  return data.user.id;
}

/** Lee un valor de platform_settings (solo servidor). */
export async function setting(db: SupabaseClient, key: string): Promise<string | null> {
  const { data, error } = await db.from('platform_settings').select('value').eq('key', key).maybeSingle();
  if (error) throw error;
  const v = data?.value;
  return v === null || v === undefined ? null : typeof v === 'string' ? v : JSON.stringify(v);
}
