// Mercado Pago: firma de webhooks, preferencias y consulta de pagos.
// Docs: https://www.mercadopago.cl/developers/es/docs/checkout-pro/payment-notifications

const API = 'https://api.mercadopago.com';

export type MpEnvironment = 'test' | 'prod';

export function mpEnvironment(): MpEnvironment {
  return Deno.env.get('MP_ENVIRONMENT') === 'prod' ? 'prod' : 'test';
}

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Verifica el header x-signature de Mercado Pago.
 * Plantilla: "id:{data.id};request-id:{x-request-id};ts:{ts};" (se omiten las partes que no vienen).
 */
export async function verifyMpSignature(opts: {
  secret: string;
  signatureHeader: string | null;
  requestId: string | null;
  dataId: string | null;
  maxAgeSeconds?: number;
  now?: number;
}): Promise<boolean> {
  const { secret, signatureHeader, requestId, dataId } = opts;
  if (!signatureHeader) return false;
  const parts = Object.fromEntries(
    signatureHeader.split(',').map((p) => {
      const [k, ...rest] = p.trim().split('=');
      return [k, rest.join('=')];
    }),
  );
  const ts = parts['ts'];
  const v1 = parts['v1'];
  if (!ts || !v1) return false;

  if (opts.maxAgeSeconds) {
    const tsSeconds = Number(ts) > 1e12 ? Number(ts) / 1000 : Number(ts);
    const nowSeconds = (opts.now ?? Date.now()) / 1000;
    if (!Number.isFinite(tsSeconds) || Math.abs(nowSeconds - tsSeconds) > opts.maxAgeSeconds) return false;
  }

  const id = dataId && /^[a-z0-9]+$/i.test(dataId) ? dataId.toLowerCase() : dataId;
  let manifest = '';
  if (id) manifest += `id:${id};`;
  if (requestId) manifest += `request-id:${requestId};`;
  manifest += `ts:${ts};`;

  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = toHex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest)));
  return timingSafeEqual(sig, v1.toLowerCase());
}

export type MpPreferenceInput = {
  bookingId: string;
  title: string;
  amountClp: number;
  payerEmail?: string | null;
  notificationUrl: string;
  returnUrl: string;
  expiresAt: Date;
};

export async function createPreference(accessToken: string, input: MpPreferenceInput) {
  const res = await fetch(`${API}/checkout/preferences`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'X-Idempotency-Key': `rue-pref-${input.bookingId}-${input.amountClp}`,
    },
    body: JSON.stringify({
      items: [
        {
          id: input.bookingId,
          title: input.title.slice(0, 250),
          quantity: 1,
          currency_id: 'CLP',
          unit_price: input.amountClp,
        },
      ],
      external_reference: input.bookingId,
      metadata: { booking_id: input.bookingId },
      notification_url: input.notificationUrl,
      back_urls: { success: input.returnUrl, failure: input.returnUrl, pending: input.returnUrl },
      auto_return: 'approved',
      statement_descriptor: 'RUE',
      expires: true,
      expiration_date_to: input.expiresAt.toISOString(),
      ...(input.payerEmail ? { payer: { email: input.payerEmail } } : {}),
    }),
  });
  if (!res.ok) {
    throw new Error(`Mercado Pago respondió ${res.status} al crear la preferencia`);
  }
  return (await res.json()) as { id: string; init_point: string; sandbox_init_point?: string };
}

export type MpPayment = {
  id: number;
  status: string; // approved | pending | in_process | rejected | refunded | cancelled | charged_back
  status_detail: string;
  transaction_amount: number;
  currency_id: string;
  external_reference: string | null;
  live_mode: boolean;
};

export async function getPayment(accessToken: string, paymentId: string): Promise<MpPayment | null> {
  const res = await fetch(`${API}/v1/payments/${encodeURIComponent(paymentId)}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Mercado Pago respondió ${res.status} al consultar el pago`);
  return (await res.json()) as MpPayment;
}
