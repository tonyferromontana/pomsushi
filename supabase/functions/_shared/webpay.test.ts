import { assert, assertEquals, assertFalse, assertThrows } from 'jsr:@std/assert@1';

import { isAllowedAppRedirect } from './redirect.ts';
import { decideOutcome, newBuyOrder, paymentTypeLabel, readReturnParams, webpayConfig, type TbkTransaction } from './webpay.ts';

const ok: TbkTransaction = {
  amount: 105000,
  status: 'AUTHORIZED',
  response_code: 0,
  buy_order: 'RUEABC',
  session_id: 'b1',
  payment_type_code: 'VC',
  installments_number: 3,
};

Deno.test('orden de compra: máximo 26 caracteres y distinta cada vez', () => {
  const a = newBuyOrder();
  const b = newBuyOrder();
  assert(a.length <= 26 && a.startsWith('RUE'));
  assert(a !== b);
});

Deno.test('ambiente de pruebas usa credenciales públicas de integración', () => {
  const cfg = webpayConfig(() => undefined);
  assertEquals(cfg.environment, 'test');
  assertEquals(cfg.baseUrl, 'https://webpay3gint.transbank.cl');
  assertEquals(cfg.commerceCode, '597055555532');
});

Deno.test('producción exige credenciales propias', () => {
  assertThrows(() => webpayConfig((n) => (n === 'TBK_ENVIRONMENT' ? 'prod' : undefined)));
  const cfg = webpayConfig((n) => ({ TBK_ENVIRONMENT: 'prod', TBK_COMMERCE_CODE: '5970', TBK_API_KEY: 'k' })[n]);
  assertEquals(cfg.baseUrl, 'https://webpay3g.transbank.cl');
});

Deno.test('solo AUTHORIZED con response_code 0 se aprueba', () => {
  assertEquals(decideOutcome(ok, 105000, 'RUEABC'), 'approved');
  assertEquals(decideOutcome({ ...ok, status: 'FAILED', response_code: -1 }, 105000, 'RUEABC'), 'rejected');
  assertEquals(decideOutcome({ ...ok, response_code: -3 }, 105000, 'RUEABC'), 'rejected');
});

Deno.test('monto u orden distintos no confirman la reserva', () => {
  assertEquals(decideOutcome({ ...ok, amount: 1000 }, 105000, 'RUEABC'), 'amount_mismatch');
  assertEquals(decideOutcome({ ...ok, buy_order: 'OTRA' }, 105000, 'RUEABC'), 'amount_mismatch');
});

Deno.test('retorno por POST (formulario) y por GET', async () => {
  const post = new Request('https://x/functions/v1/webpay-return?r=rue%3A%2F%2Fpago', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'token_ws=abc123',
  });
  assertEquals((await readReturnParams(post)).token, 'abc123');
  const get = new Request('https://x/functions/v1/webpay-return?token_ws=zzz');
  assertEquals((await readReturnParams(get)).token, 'zzz');
  const abort = new Request('https://x/functions/v1/webpay-return?TBK_TOKEN=t1&TBK_ORDEN_COMPRA=RUE1');
  const p = await readReturnParams(abort);
  assertEquals(p.token, null);
  assertEquals(p.abortedToken, 't1');
});

Deno.test('etiquetas de tipo de pago', () => {
  assertEquals(paymentTypeLabel('VC'), 'crédito en cuotas');
  assertEquals(paymentTypeLabel('VD'), 'débito');
});

Deno.test('solo se permite volver a la app', () => {
  assert(isAllowedAppRedirect('rue://pago'));
  assert(isAllowedAppRedirect('exp://192.168.1.5:8081/--/pago'));
  assertFalse(isAllowedAppRedirect('https://sitio-malicioso.com'));
  assertFalse(isAllowedAppRedirect('javascript:alert(1)'));
  assertFalse(isAllowedAppRedirect(null));
});
