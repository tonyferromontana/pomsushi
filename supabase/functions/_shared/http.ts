// Utilidades HTTP comunes para las Edge Functions de RUÉ.

export const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

/** Error con mensaje apto para mostrar a la persona (en español). */
export class PublicError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

export function handleError(context: string, err: unknown): Response {
  if (err instanceof PublicError) return json({ error: err.message }, err.status);
  // Log sin secretos: solo el mensaje.
  console.error(`[${context}]`, err instanceof Error ? err.message : String(err));
  return json({ error: 'Algo salió mal. Inténtalo de nuevo en unos minutos.' }, 500);
}

export function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Falta la variable de entorno ${name}`);
  return v;
}
