-- =============================================================================
-- RUÉ · 0007 · Pagos con Webpay Plus (Transbank) en vez de Mercado Pago
--
-- Decisión del dueño (2026-10-01): todos los pagos por Webpay. El arrendatario
-- puede pagar en cuotas con su tarjeta de crédito (lo ofrece el formulario de
-- Webpay según el contrato del comercio y el banco emisor).
--
--   * payments: + buy_order (orden de compra enviada a Transbank), payment_type
--     (VD débito, VN crédito, VC/SI/S2/NC cuotas, VP prepago), installments.
--   * confirm_booking_payment y record_payment_status reciben el proveedor.
--   * Webpay no tiene webhook: la confirmación la hace el servidor al recibir el
--     retorno (commit servidor-a-servidor). Sin commit, Transbank reversa solo.
-- =============================================================================

alter table public.payments alter column provider set default 'webpay';
alter table public.payments add column if not exists buy_order text;
alter table public.payments add column if not exists payment_type text;
alter table public.payments add column if not exists installments int check (installments is null or installments between 0 and 48);

create unique index if not exists payments_buy_order_unique on public.payments (buy_order) where buy_order is not null;
create index if not exists payments_preference_idx on public.payments (preference_id);

-- -----------------------------------------------------------------------------
-- Confirmación de pago con proveedor explícito (reemplaza la de 0002)
-- -----------------------------------------------------------------------------

drop function if exists public.confirm_booking_payment(uuid, text, int, text);

create or replace function public.confirm_booking_payment(
  p_booking_id uuid,
  p_provider_payment_id text,
  p_amount_clp int,
  p_environment text,
  p_provider text default 'webpay'
)
returns text   -- 'confirmed' | 'already_confirmed' | 'amount_mismatch' | 'not_payable'
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;

  insert into public.payments (booking_id, provider, environment, provider_payment_id, status, amount_clp)
  values (b.id, p_provider, p_environment, p_provider_payment_id, 'approved', p_amount_clp)
  on conflict (provider, provider_payment_id)
  do update set status = 'approved';

  if b.status in ('confirmada', 'en_curso', 'devuelta', 'finalizada', 'disputada') then
    return 'already_confirmed';
  end if;

  if p_amount_clp <> b.total_clp then
    return 'amount_mismatch';
  end if;

  if b.status <> 'aceptada' then
    return 'not_payable';
  end if;

  perform set_config('rue.transition_note', 'Pago aprobado ' || p_provider_payment_id, true);
  update public.bookings set status = 'confirmada', expires_at = null where id = b.id;
  perform set_config('rue.transition_note', '', true);
  return 'confirmed';
end;
$$;

drop function if exists public.record_payment_status(uuid, text, text, text, int, text);

create or replace function public.record_payment_status(
  p_booking_id uuid,
  p_provider_payment_id text,
  p_status text,
  p_status_detail text,
  p_amount_clp int,
  p_environment text,
  p_provider text default 'webpay'
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  insert into public.payments (booking_id, provider, environment, provider_payment_id, status, status_detail, amount_clp)
  values (p_booking_id, p_provider, p_environment, p_provider_payment_id, p_status, p_status_detail, p_amount_clp)
  on conflict (provider, provider_payment_id)
  do update set status = excluded.status, status_detail = excluded.status_detail;

  if p_status = 'rejected' then
    insert into public.notifications (user_id, kind, title, body, booking_id)
    select b.renter_id, 'payment_failed', 'El pago no se aprobó',
           'Prueba con otra tarjeta antes de que venza tu reserva.', b.id
      from public.bookings b where b.id = p_booking_id and b.status = 'aceptada';
  elsif p_status = 'refunded' then
    insert into public.notifications (user_id, kind, title, body, booking_id)
    select b.renter_id, 'payment_refunded', 'Te devolvimos el pago',
           'La reserva ya no estaba disponible, así que anulamos el cargo en tu tarjeta.', b.id
      from public.bookings b where b.id = p_booking_id;
  end if;
end;
$$;

revoke execute on function public.confirm_booking_payment(uuid, text, int, text, text) from public, anon, authenticated;
revoke execute on function public.record_payment_status(uuid, text, text, text, int, text, text) from public, anon, authenticated;
grant execute on function public.confirm_booking_payment(uuid, text, int, text, text) to service_role;
grant execute on function public.record_payment_status(uuid, text, text, text, int, text, text) to service_role;
