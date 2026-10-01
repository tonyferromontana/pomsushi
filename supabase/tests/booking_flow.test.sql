-- Pruebas del motor de reservas y de la seguridad (RLS / permisos).
-- Cada bloque falla con "raise exception" si algo no se comporta como debe.
\set ON_ERROR_STOP 1

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false);
end $$;
create or replace function pg_temp.confirm_checkin(p_booking uuid) returns void language plpgsql as $$
declare me text := current_setting('request.jwt.claim.sub', true); r uuid;
begin
  select renter_id into r from public.bookings where id = p_booking;
  perform set_config('request.jwt.claim.sub', r::text, false);
  perform public.confirm_handover((select id from public.booking_handovers where booking_id = p_booking and kind = 'entrega' order by created_at desc limit 1));
  perform set_config('request.jwt.claim.sub', me, false);
end $$;

-- Usuarios de prueba
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@test.cl',  '{"display_name":"Dueña"}'),
  ('00000000-0000-0000-0000-00000000000b', 'renter@test.cl', '{"display_name":"Arrendatario"}'),
  ('00000000-0000-0000-0000-00000000000c', 'other@test.cl',  '{"display_name":"Otro"}');

do $$ begin
  if (select count(*) from public.profiles) <> 3 or (select count(*) from public.profile_private) <> 3 then
    raise exception 'FALLA: no se crearon los perfiles al registrarse';
  end if;
end $$;

-- Configuración de prueba: 10% comisión, 5% cargo de servicio (versión económica nueva)
select set_config('request.jwt.claim.role', 'service_role', false);
select public.publish_economic_config('test-booking-flow', 0.10, 0.05, 2, 'Prueba booking_flow');
select set_config('request.jwt.claim.role', '', false);

-- ---------------------------------------------------------------- Propietario
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
set role authenticated;

insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city,
                             attributes, daily_price_clp, weekly_price_clp)
values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'pickup',
        'publicado', 'Hilux 4x4 para la nieve', 'Toyota', 'Hilux', 2021, 'Santiago',
        '{"transmission":"manual","fuel":"diesel","seats":5,"traction":"4x4"}', 50000, 300000);

do $$ begin
  begin
    insert into public.vehicles (owner_id, vehicle_type, title, brand, model, year, city, attributes, daily_price_clp)
    values ('00000000-0000-0000-0000-00000000000a', 'motorcycle', 'Moto', 'Honda', 'CB', 2020, 'Santiago',
            '{"doors":2}', 20000);
    raise exception 'FALLA: aceptó atributos inválidos para una moto';
  exception when check_violation then null; end;

  begin
    insert into public.vehicles (owner_id, vehicle_type, title, brand, model, year, city, daily_price_clp)
    values ('00000000-0000-0000-0000-00000000000b', 'car', 'Auto ajeno', 'Kia', 'Rio', 2020, 'Santiago', 20000);
    raise exception 'FALLA: pudo crear un vehículo a nombre de otro';
  exception when insufficient_privilege then null; end;

  begin
    update public.vehicles set verified = true where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FALLA: el propietario pudo marcarse como verificado';
  exception when insufficient_privilege then null; end;

  begin
    update public.profiles set identity_verified = true where id = auth.uid();
    raise exception 'FALLA: el usuario pudo verificar su propia identidad';
  exception when insufficient_privilege then null; end;
end $$;

update public.profile_private set rut = '12345678-5', phone = '+56 9 1234 5678' where user_id = auth.uid();

-- ---------------------------------------------------------------- Arrendatario
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
set role authenticated;

do $$
declare
  n int;
  q jsonb;
  bid uuid;
  b public.bookings;
begin
  select count(*) into n from public.profile_private where user_id = '00000000-0000-0000-0000-00000000000a';
  if n <> 0 then raise exception 'FALLA: el arrendatario ve el RUT/teléfono del dueño'; end if;

  select count(*) into n from public.search_vehicles(p_type => 'pickup', p_city => 'santiago');
  if n <> 1 then raise exception 'FALLA: la búsqueda no encontró la camioneta (%).', n; end if;

  -- 8 días: 1 semana (300.000) + 1 día (50.000) = 350.000
  q := public.quote_booking('10000000-0000-0000-0000-000000000001', public.today_cl() + 10, public.today_cl() + 18);
  if (q->>'rental_clp')::int <> 350000 or (q->>'renter_fee_clp')::int <> 17500 or (q->>'total_clp')::int <> 367500 then
    raise exception 'FALLA: cotización incorrecta %', q;
  end if;

  bid := public.request_booking('10000000-0000-0000-0000-000000000001', public.today_cl() + 10, public.today_cl() + 18, 'viaje', 'Hola!', p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true);
  select * into b from public.bookings where id = bid;
  if b.status <> 'solicitada' or b.owner_commission_clp <> 35000 or b.owner_payout_clp <> 315000 then
    raise exception 'FALLA: reserva mal calculada %', row_to_json(b);
  end if;

  begin
    insert into public.bookings (vehicle_id, renter_id, owner_id, start_date, end_date, days, rental_clp,
      renter_fee_clp, owner_commission_clp, total_clp, owner_payout_clp, deposit_clp)
    values ('10000000-0000-0000-0000-000000000001', auth.uid(), '00000000-0000-0000-0000-00000000000a',
      current_date, current_date + 1, 1, 1, 0, 0, 1, 1, 0);
    raise exception 'FALLA: la app pudo insertar una reserva directo (con precio inventado)';
  exception when insufficient_privilege then null; end;

  begin
    update public.bookings set status = 'confirmada' where id = bid;
    raise exception 'FALLA: la app pudo cambiar el estado directo';
  exception when insufficient_privilege then null; end;

  begin
    perform public.transition_booking(bid, 'aceptada');
    raise exception 'FALLA: el arrendatario pudo aceptar su propia solicitud';
  exception when insufficient_privilege then null; end;

  begin
    perform public.request_booking('10000000-0000-0000-0000-000000000001', public.today_cl() - 1, public.today_cl() + 2, p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true);
    raise exception 'FALLA: aceptó una reserva en el pasado';
  exception when invalid_parameter_value then null; end;

  begin
    perform public.confirm_booking_payment(bid, 'pago-falso', 367500, 'test');
    raise exception 'FALLA: la app pudo confirmar un pago';
  exception when insufficient_privilege then null; end;

  perform set_config('rue.test_booking', bid::text, false);
end $$;

-- ---------------------------------------------------------------- Tercero
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
set role authenticated;

do $$
declare n int; bid uuid := current_setting('rue.test_booking')::uuid;
begin
  select count(*) into n from public.bookings where id = bid;
  if n <> 0 then raise exception 'FALLA: un tercero ve una reserva ajena'; end if;

  begin
    insert into public.messages (booking_id, sender_id, body) values (bid, auth.uid(), 'spam');
    raise exception 'FALLA: un tercero pudo escribir en un chat ajeno';
  exception when insufficient_privilege then null; end;

  -- Solicitud que se cruza (queda "solicitada"; se rechazará al aceptar la otra)
  perform set_config('rue.test_booking_c',
    public.request_booking('10000000-0000-0000-0000-000000000001', public.today_cl() + 12, public.today_cl() + 14, p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);
end $$;

-- ---------------------------------------------------------------- Propietario acepta
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
set role authenticated;

do $$
declare bid uuid := current_setting('rue.test_booking')::uuid; b public.bookings;
begin
  b := public.accept_booking(bid, '10:00', '18:00');
  if b.status <> 'aceptada' or b.expires_at is null then raise exception 'FALLA: no quedó aceptada'; end if;

  if (select status from public.bookings where id = current_setting('rue.test_booking_c')::uuid) <> 'rechazada' then
    raise exception 'FALLA: la solicitud que se cruzaba no se rechazó';
  end if;

  begin
    perform public.transition_booking(bid, 'confirmada');
    raise exception 'FALLA: el dueño pudo confirmar sin pago';
  exception when insufficient_privilege then null; end;

  insert into public.messages (booking_id, sender_id, body) values (bid, auth.uid(), 'Te espero en Providencia');
end $$;

-- Tercero ya no puede pedir esas fechas
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
set role authenticated;
do $$ begin
  begin
    perform public.request_booking('10000000-0000-0000-0000-000000000001', public.today_cl() + 11, public.today_cl() + 13, p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true);
    raise exception 'FALLA: permitió solicitar fechas ya aceptadas';
  exception when raise_exception then null; end;
  if (select count(*) from public.messages) <> 0 then raise exception 'FALLA: un tercero lee mensajes ajenos'; end if;
end $$;

-- ---------------------------------------------------------------- Servidor: pago
reset role;
select pg_temp.as_user(null);
set role service_role;
do $$
declare bid uuid := current_setting('rue.test_booking')::uuid; r text;
begin
  r := public.confirm_booking_payment(bid, 'mp-123', 1000, 'test');
  if r <> 'amount_mismatch' then raise exception 'FALLA: aceptó un monto distinto (%)', r; end if;
  r := public.confirm_booking_payment(bid, 'mp-124', 367500, 'test');
  if r <> 'confirmed' then raise exception 'FALLA: no confirmó el pago (%)', r; end if;
  r := public.confirm_booking_payment(bid, 'mp-124', 367500, 'test');
  if r <> 'already_confirmed' then raise exception 'FALLA: el webhook repetido no fue idempotente (%)', r; end if;
  if (select count(*) from public.payments where provider_payment_id = 'mp-124') <> 1 then
    raise exception 'FALLA: pago duplicado';
  end if;
end $$;

-- ---------------------------------------------------------------- Entrega antes de tiempo
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$ begin
  begin
    perform public.submit_handover(current_setting('rue.test_booking')::uuid, 'entrega', 1000, 100, 'ok', '{}');
  perform public.transition_booking(current_setting('rue.test_booking')::uuid, 'en_curso');
    raise exception 'FALLA: permitió entregar antes de la fecha de inicio';
  exception when raise_exception then null; end;
end $$;

-- ---------------------------------------------------------------- Flujo completo que parte hoy
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
set role authenticated;
select set_config('rue.b2', public.request_booking('10000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2, p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);

reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.accept_booking(current_setting('rue.b2')::uuid, '10:00', '18:00') is not null;

reset role;
select pg_temp.as_user(null);
set role service_role;
select public.confirm_booking_payment(current_setting('rue.b2')::uuid, 'mp-200', 105000, 'test') = 'confirmed' as pagado;

reset role;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.b2')::uuid;
begin
  perform public.submit_handover(bid, 'entrega', 1000, 100, 'ok', '{}');
  perform pg_temp.confirm_checkin(bid);
  perform public.transition_booking(bid, 'en_curso');
  perform public.submit_handover(bid, 'devolucion', 1300, 90, 'ok', '{}');
  perform public.transition_booking(bid, 'devuelta');
  perform public.transition_booking(bid, 'finalizada');
  if (select count(*) from public.booking_events where booking_id = bid) <> 6 then
    raise exception 'FALLA: el historial no registró los 6 estados';
  end if;
end $$;

-- ---------------------------------------------------------------- Saltos inválidos (incluso como superusuario)
reset role;
do $$
declare bid uuid;
begin
  select id into bid from public.bookings where status = 'rechazada' limit 1;
  begin
    update public.bookings set status = 'finalizada' where id = bid;
    raise exception 'FALLA: permitió rechazada → finalizada';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    update public.bookings set total_clp = 1 where id = current_setting('rue.b2')::uuid;
    raise exception 'FALLA: permitió cambiar el monto de una reserva';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
end $$;

-- ---------------------------------------------------------------- Vencimientos (cron)
update public.platform_settings set value = '24' where key = 'request_expiry_hours';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
set role authenticated;
select set_config('rue.b3', public.request_booking('10000000-0000-0000-0000-000000000001', public.today_cl() + 30, public.today_cl() + 32, p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);
reset role;
update public.bookings set expires_at = now() - interval '1 minute' where id = current_setting('rue.b3')::uuid;
set role service_role;
do $$ begin
  if public.expire_stale_bookings() <> 1 then raise exception 'FALLA: no venció la solicitud sin respuesta'; end if;
end $$;
reset role;

-- ---------------------------------------------------------------- Anónimo
set role anon;
do $$ begin
  begin
    perform public.search_vehicles();
    raise exception 'FALLA: un anónimo pudo usar la búsqueda';
  exception when insufficient_privilege then null; end;
  if (select count(*) from public.bookings) <> 0 then raise exception 'FALLA'; end if;
exception when insufficient_privilege then null;
end $$;
reset role;

select 'todas las pruebas pasaron' as resultado;
