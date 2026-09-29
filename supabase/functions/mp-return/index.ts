// Mercado Pago devuelve a la persona aquí después de pagar; la mandamos de vuelta a la app.
// OJO: esto NO confirma nada. La confirmación llega solo por mp-webhook.
import { isAllowedAppRedirect } from '../_shared/redirect.ts';

Deno.serve((req) => {
  const url = new URL(req.url);
  const redirect = url.searchParams.get('redirect');
  const status = url.searchParams.get('status') ?? url.searchParams.get('collection_status') ?? 'unknown';
  const booking = url.searchParams.get('booking') ?? '';
  if (!isAllowedAppRedirect(redirect)) {
    return new Response('Vuelve a la app RUÉ para ver el estado de tu reserva.', {
      status: 200,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
  const target = new URL(redirect);
  target.searchParams.set('status', status);
  target.searchParams.set('booking', booking);
  return new Response(null, { status: 302, headers: { Location: target.toString() } });
});
