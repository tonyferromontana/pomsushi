import { assert, assertFalse } from 'jsr:@std/assert@1';

import { verifyMpSignature } from './mercadopago.ts';
import { isAllowedAppRedirect } from './redirect.ts';

async function sign(secret: string, manifest: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

Deno.test('firma válida de Mercado Pago', async () => {
  const ts = '1704908010';
  const v1 = await sign('secreto', `id:123456;request-id:req-1;ts:${ts};`);
  assert(await verifyMpSignature({ secret: 'secreto', signatureHeader: `ts=${ts},v1=${v1}`, requestId: 'req-1', dataId: '123456' }));
});

Deno.test('data.id alfanumérico se compara en minúsculas', async () => {
  const ts = '1704908010';
  const v1 = await sign('secreto', `id:abc123;request-id:req-1;ts:${ts};`);
  assert(await verifyMpSignature({ secret: 'secreto', signatureHeader: `ts=${ts}, v1=${v1}`, requestId: 'req-1', dataId: 'ABC123' }));
});

Deno.test('firma alterada, secreto distinto o sin header se rechazan', async () => {
  const ts = '1704908010';
  const v1 = await sign('secreto', `id:123456;request-id:req-1;ts:${ts};`);
  assertFalse(await verifyMpSignature({ secret: 'otro', signatureHeader: `ts=${ts},v1=${v1}`, requestId: 'req-1', dataId: '123456' }));
  assertFalse(await verifyMpSignature({ secret: 'secreto', signatureHeader: `ts=${ts},v1=${v1}`, requestId: 'req-1', dataId: '999' }));
  assertFalse(await verifyMpSignature({ secret: 'secreto', signatureHeader: null, requestId: 'req-1', dataId: '123456' }));
  assertFalse(await verifyMpSignature({ secret: 'secreto', signatureHeader: 'basura', requestId: 'req-1', dataId: '123456' }));
});

Deno.test('firma antigua se rechaza si se pide antigüedad máxima', async () => {
  const ts = '1704908010';
  const v1 = await sign('secreto', `id:1;ts:${ts};`);
  assertFalse(
    await verifyMpSignature({ secret: 'secreto', signatureHeader: `ts=${ts},v1=${v1}`, requestId: null, dataId: '1', maxAgeSeconds: 60, now: Date.now() }),
  );
  assert(
    await verifyMpSignature({ secret: 'secreto', signatureHeader: `ts=${ts},v1=${v1}`, requestId: null, dataId: '1', maxAgeSeconds: 60, now: 1704908010 * 1000 + 5000 }),
  );
});

Deno.test('solo se permite volver a la app', () => {
  assert(isAllowedAppRedirect('rue://pago'));
  assert(isAllowedAppRedirect('exp://192.168.1.5:8081/--/pago'));
  assertFalse(isAllowedAppRedirect('https://sitio-malicioso.com'));
  assertFalse(isAllowedAppRedirect('javascript:alert(1)'));
  assertFalse(isAllowedAppRedirect(null));
});
