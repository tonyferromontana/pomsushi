// Webpay Plus (Transbank) — API REST v1.2.
// Docs: https://www.transbankdevelopers.cl/referencia/webpay
//
// Flujo: crear transacción → la persona paga en el formulario de Webpay (puede
// elegir cuotas con su tarjeta de crédito) → Transbank la devuelve a return_url
// con token_ws → el SERVIDOR confirma (commit). Si nadie confirma, Transbank
// reversa el cargo solo. No hay webhook.

export type TbkEnvironment = 'test' | 'prod';

/** Credenciales públicas del ambiente de integración de Transbank (documentadas por ellos). */
const INTEGRATION = {
  commerceCode: '597055555532',
  apiKey: '579B532A7440BB0C9079DED94D31EA1615BACEB56610332264630D42D0A36B1C',
};

export type WebpayConfig = { environment: TbkEnvironment; baseUrl: string; commerceCode: string; apiKey: string };

export function webpayConfig(env: (name: string) => string | undefined = (n) => Deno.env.get(n)): WebpayConfig {
  const environment: TbkEnvironment = env('TBK_ENVIRONMENT') === 'prod' ? 'prod' : 'test';
  const commerceCode = env('TBK_COMMERCE_CODE');
  const apiKey = env('TBK_API_KEY');
  if (environment === 'prod') {
    if (!commerceCode || !apiKey) throw new Error('Faltan TBK_COMMERCE_CODE o TBK_API_KEY para producción');
    return { environment, baseUrl: 'https://webpay3g.transbank.cl', commerceCode, apiKey };
  }
  return {
    environment,
    baseUrl: 'https://webpay3gint.transbank.cl',
    commerceCode: commerceCode ?? INTEGRATION.commerceCode,
    apiKey: apiKey ?? INTEGRATION.apiKey,
  };
}

const PATH = '/rswebpaytransaction/api/webpay/v1.2/transactions';

function headers(cfg: WebpayConfig): HeadersInit {
  return {
    'Tbk-Api-Key-Id': cfg.commerceCode,
    'Tbk-Api-Key-Secret': cfg.apiKey,
    'Content-Type': 'application/json',
  };
}

/** Orden de compra: máximo 26 caracteres, única. */
export function newBuyOrder(now = Date.now(), rand = Math.random): string {
  const r = Math.floor(rand() * 36 ** 6).toString(36).padStart(6, '0');
  return `RUE${now.toString(36)}${r}`.toUpperCase().slice(0, 26);
}

export class TbkError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

async function call<T>(cfg: WebpayConfig, method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${cfg.baseUrl}${PATH}${path}`, {
    method,
    headers: headers(cfg),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    // Transbank responde { error_message } — no incluye datos sensibles.
    let msg = text;
    try {
      msg = (JSON.parse(text) as { error_message?: string }).error_message ?? text;
    } catch {
      // cuerpo no JSON: se usa tal cual
    }
    throw new TbkError(`Transbank ${res.status}: ${msg.slice(0, 200)}`, res.status);
  }
  return (text ? JSON.parse(text) : {}) as T;
}

export function createTransaction(cfg: WebpayConfig, input: { buyOrder: string; sessionId: string; amount: number; returnUrl: string }) {
  return call<{ token: string; url: string }>(cfg, 'POST', '', {
    buy_order: input.buyOrder,
    session_id: input.sessionId.slice(0, 61),
    amount: input.amount,
    return_url: input.returnUrl,
  });
}

export type TbkTransaction = {
  vci?: string;
  amount: number;
  status: string; // AUTHORIZED | FAILED | REVERSED | NULLIFIED | PARTIALLY_NULLIFIED | INITIALIZED
  buy_order: string;
  session_id: string;
  authorization_code?: string;
  payment_type_code?: string; // VD, VN, VC, SI, S2, NC, VP
  response_code?: number; // 0 = aprobada
  installments_number?: number;
  installments_amount?: number;
};

export function commitTransaction(cfg: WebpayConfig, token: string) {
  return call<TbkTransaction>(cfg, 'PUT', `/${encodeURIComponent(token)}`);
}

export function getTransaction(cfg: WebpayConfig, token: string) {
  return call<TbkTransaction>(cfg, 'GET', `/${encodeURIComponent(token)}`);
}

export function refundTransaction(cfg: WebpayConfig, token: string, amount: number) {
  return call<{ type: string; response_code?: number }>(cfg, 'POST', `/${encodeURIComponent(token)}/refunds`, { amount });
}

/** Qué hacer con el resultado de Transbank. */
export type Outcome = 'approved' | 'rejected' | 'amount_mismatch';

export function decideOutcome(tx: TbkTransaction, expectedAmount: number, expectedBuyOrder: string): Outcome {
  const authorized = tx.status === 'AUTHORIZED' && tx.response_code === 0;
  if (!authorized) return 'rejected';
  if (Math.round(tx.amount) !== expectedAmount || tx.buy_order !== expectedBuyOrder) return 'amount_mismatch';
  return 'approved';
}

/** Parámetros con los que Transbank vuelve a return_url (GET o POST form). */
export type ReturnParams = { token: string | null; abortedToken: string | null; buyOrder: string | null };

export async function readReturnParams(req: Request): Promise<ReturnParams> {
  const url = new URL(req.url);
  const get = (k: string) => url.searchParams.get(k);
  let form: URLSearchParams | null = null;
  if (req.method === 'POST') {
    try {
      form = new URLSearchParams(await req.text());
    } catch {
      form = null;
    }
  }
  const pick = (k: string) => form?.get(k) ?? get(k);
  return {
    token: pick('token_ws'),
    abortedToken: pick('TBK_TOKEN'),
    buyOrder: pick('TBK_ORDEN_COMPRA'),
  };
}

export function paymentTypeLabel(code: string | undefined): string {
  switch (code) {
    case 'VD':
      return 'débito';
    case 'VP':
      return 'prepago';
    case 'VN':
      return 'crédito';
    case 'VC':
    case 'SI':
    case 'S2':
    case 'NC':
      return 'crédito en cuotas';
    default:
      return 'tarjeta';
  }
}
