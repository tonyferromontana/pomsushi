/**
 * Solo se permite volver a la app (esquema rue://) o a Expo Go (exp://, exps://) en desarrollo.
 * Evita que el link de retorno se use para redirigir a sitios externos.
 */
export function isAllowedAppRedirect(url: string | null): url is string {
  if (!url) return false;
  return /^(rue|exps?):\/\/[^\s]*$/.test(url) && url.length <= 300;
}
