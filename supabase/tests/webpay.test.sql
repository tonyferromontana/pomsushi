-- Pruebas de 0007: pagos con proveedor Webpay, anulación automática y avisos.
\set ON_ERROR_STOP 1

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false);
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('80000000-0000-0000-0000-00000000000a', 'o7@test.cl', '{"display_name":"Owner7"}'),
  ('80000000-0000-0000-0000-00000000000b', 'r7@test.cl', '{"display_name":"Renter7"}');
update public.platform_settings set value = 'false' where key in ('require_verified_license', 'require_vehicle_verification');
select set_config('request.jwt.claim.role', 'service_role', false);
select public.publish_economic_config('test-webpay', 0, 0, 2, 'Prueba webpay: sin comisiones');
select set_config('request.jwt.claim.role', '', false);

select pg_temp.as_user('80000000-0000-0000-0000-00000000000a');
set role authenticated;
insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp)
values ('90000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-00000000000a', 'van', 'publicado',
        'Van 12 pasajeros', 'Hyundai', 'H1', 2021, 'Santiago', 70000);
reset role;

select pg_temp.as_user('80000000-0000-0000-0000-00000000000b');
set role authenticated;
select set_config('rue.w1', public.request_booking('90000000-0000-0000-0000-000000000001', public.today_cl() + 4, public.today_cl() + 6,
  p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);
reset role;

select pg_temp.as_user('80000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.accept_booking(current_setting('rue.w1')::uuid, '10:00', '18:00') is not null;
reset role;

set role service_role;
select pg_temp.as_user(null);
do $$
declare bid uuid := current_setting('rue.w1')::uuid;
begin
  -- Como lo hace webpay-create: fila 'created' con token y orden de compra
  insert into public.payments (booking_id, environment, preference_id, buy_order, status, amount_clp)
  values (bid, 'test', 'tok-1', 'RUEORDER1', 'created', 140000);
  if (select provider from public.payments where buy_order = 'RUEORDER1') <> 'webpay' then
    raise exception 'FALLA: el proveedor por defecto no es webpay';
  end if;
  update public.payments set provider_payment_id = 'RUEORDER1', status = 'approved', payment_type = 'VC', installments = 3
   where buy_order = 'RUEORDER1';
  if public.confirm_booking_payment(bid, 'RUEORDER1', 140000, 'test', 'webpay') <> 'confirmed' then
    raise exception 'FALLA: no se confirmó el pago webpay';
  end if;
  if (select count(*) from public.payments where booking_id = bid) <> 1 then
    raise exception 'FALLA: la confirmación duplicó el registro de pago';
  end if;
  -- Segundo pago de la misma reserva: queda "already_confirmed" y la función lo anula
  if public.confirm_booking_payment(bid, 'RUEORDER2', 140000, 'test', 'webpay') <> 'already_confirmed' then
    raise exception 'FALLA: el pago doble no se detectó';
  end if;
  perform public.record_payment_status(bid, 'RUEORDER2', 'refunded', 'pago doble', 140000, 'test', 'webpay');
  if (select status from public.payments where provider_payment_id = 'RUEORDER2') <> 'refunded' then
    raise exception 'FALLA: no quedó registrada la anulación';
  end if;
end $$;
reset role;

do $$ begin
  if not exists (select 1 from public.notifications where booking_id = current_setting('rue.w1')::uuid and kind = 'payment_refunded') then
    raise exception 'FALLA: no se avisó la devolución';
  end if;
end $$;

-- El arrendatario ve sus cuotas; nadie ajeno ve el pago
select pg_temp.as_user('80000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$ begin
  if (select installments from public.payments where buy_order = 'RUEORDER1') <> 3 then
    raise exception 'FALLA: el arrendatario no ve sus cuotas';
  end if;
end $$;
reset role;

select 'pruebas de webpay OK' as resultado;
