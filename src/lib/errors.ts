/**
 * Convierte errores técnicos en mensajes claros para la persona.
 * Los mensajes del servidor (funciones SQL de RUÉ) ya vienen en español y se muestran tal cual.
 */

type MaybeError = { message?: string; code?: string; status?: number; name?: string } | null | undefined;

const SERVER_CODES_WITH_FRIENDLY_MESSAGE = new Set(['P0001', 'P0002', '22023', '42501']);

export function friendlyError(err: unknown, fallback = 'Algo salió mal. Inténtalo de nuevo.'): string {
  const e = err as MaybeError;
  if (!e) return fallback;
  const msg = e.message ?? '';

  if (e.code && SERVER_CODES_WITH_FRIENDLY_MESSAGE.has(e.code) && msg) return msg;

  if (/network request failed|failed to fetch|fetch failed|network/i.test(msg)) {
    return 'No pudimos conectarnos. Revisa tu internet e inténtalo de nuevo.';
  }
  if (/invalid login credentials/i.test(msg)) return 'El correo o la contraseña no coinciden.';
  if (/email not confirmed/i.test(msg)) return 'Te falta confirmar tu correo. Revisa tu bandeja de entrada.';
  if (/user already registered/i.test(msg)) return 'Ya existe una cuenta con ese correo. Prueba iniciando sesión.';
  if (/password should be at least/i.test(msg)) return 'La contraseña debe tener al menos 6 caracteres.';
  if (/rate limit|too many/i.test(msg)) return 'Hiciste demasiados intentos. Espera un momento y vuelve a probar.';
  if (/rut/i.test(msg) && /check/i.test(msg)) return 'Revisa el RUT: debe ir sin puntos y con guion, por ejemplo 12345678-5.';
  if (/phone/i.test(msg) && /check/i.test(msg)) return 'Revisa el teléfono, por ejemplo +56 9 1234 5678.';

  return fallback;
}

/** Log para diagnóstico en desarrollo (nunca incluye tokens ni datos sensibles) */
export function logError(context: string, err: unknown): void {
  const e = err as MaybeError;
  console.warn(`[RUÉ] ${context}:`, e?.code ?? '', e?.message ?? String(err));
}
