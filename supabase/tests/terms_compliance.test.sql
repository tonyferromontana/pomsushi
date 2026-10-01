-- Pruebas de 0005: verificación de dominio del vehículo, casillas por reserva,
-- actas de entrega/devolución y bitácora de comunicación de datos.
\set ON_ERROR_STOP 1

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false);
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('40000000-0000-0000-0000-00000000000a', 'o3@test.cl', '{"display_name":"Owner3"}'),
  ('40000000-0000-0000-0000-00000000000b', 'r3@test.cl', '{"display_name":"Renter3"}'),
  ('40000000-0000-0000-0000-0000000000ad', 'admin3@test.cl', '{"display_name":"Admin3"}');
insert into public.admins (user_id) values ('40000000-0000-0000-0000-0000000000ad');
update public.platform_settings set value = 'false' where key = 'require_verified_license';
update public.platform_settings set value = 'true' where key = 'require_vehicle_verification';
select set_config('request.jwt.claim.role', 'service_role', false);
select public.publish_economic_config('test-terms_compliance', 0, 0, 2, 'Prueba terms_compliance: sin comisiones');
select set_config('request.jwt.claim.role', '', false);

-- ------------------------------------------------ Publicar exige verificación
select pg_temp.as_user('40000000-0000-0000-0000-00000000000a');
set role authenticated;
insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp, plate, km_per_day, pickup_location)
values ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-00000000000a', 'motorcycle', 'borrador',
        'Moto para reparto', 'Honda', 'CB190', 2023, 'Santiago', 18000, 'ABCD12', 200, 'Metro Tobalaba');
do $$ begin
  begin
    update public.vehicles set status = 'publicado' where id = '50000000-0000-0000-0000-000000000001';
    raise exception 'FALLA: se publicó sin verificar el dominio';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    perform public.submit_vehicle_verification('50000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-00000000000a/cav.pdf', '40000000-0000-0000-0000-00000000000a/padron.pdf', public.today_cl() - 45);
    raise exception 'FALLA: aceptó un certificado de más de 30 días';
  exception when invalid_parameter_value then null; end;
  perform public.submit_vehicle_verification('50000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-00000000000a/cav.pdf', '40000000-0000-0000-0000-00000000000a/padron.pdf', public.today_cl() - 3);
  begin
    perform public.review_vehicle_verification((select id from public.vehicle_verifications limit 1), true);
    raise exception 'FALLA: el propietario aprobó su propio vehículo';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select pg_temp.as_user('40000000-0000-0000-0000-0000000000ad');
set role authenticated;
select public.review_vehicle_verification(
  (select id from public.vehicle_verifications where vehicle_id = '50000000-0000-0000-0000-000000000001'), true, null);
reset role;

do $$ begin
  if (select verified_until from public.vehicles where id = '50000000-0000-0000-0000-000000000001') < public.today_cl() + 170 then
    raise exception 'FALLA: la verificación no quedó vigente por 6 meses';
  end if;
end $$;

select pg_temp.as_user('40000000-0000-0000-0000-00000000000a');
set role authenticated;
update public.vehicles set status = 'publicado' where id = '50000000-0000-0000-0000-000000000001';
reset role;

-- ------------------------------------------------ Casillas por reserva
select pg_temp.as_user('40000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$ begin
  begin
    perform public.request_booking('50000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2);
    raise exception 'FALLA: permitió reservar sin aceptar los términos';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.request_booking('50000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2,
      p_terms_version => '2020-01-01', p_accept_terms => true, p_accept_data_sharing => true);
    raise exception 'FALLA: aceptó una versión vieja de los términos';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  perform set_config('rue.t5', public.request_booking('50000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2,
    p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);
  if not exists (select 1 from public.booking_consents where booking_id = current_setting('rue.t5')::uuid
                 and terms_accepted and data_sharing_accepted and terms_version = '2026-10-01') then
    raise exception 'FALLA: no se registraron las casillas de la reserva';
  end if;
end $$;
reset role;

select pg_temp.as_user('40000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.accept_booking(current_setting('rue.t5')::uuid, '10:00', '18:00') is not null;
reset role;
set role service_role;
do $$ begin
  if public.confirm_booking_payment(current_setting('rue.t5')::uuid, 'mp-t5', 36000, 'test') <> 'confirmed' then
    raise exception 'FALLA: no se confirmó el pago';
  end if;
end $$;
reset role;

-- ------------------------------------------------ Actas obligatorias
select pg_temp.as_user('40000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.t5')::uuid;
begin
  begin
    perform public.transition_booking(bid, 'en_curso');
    raise exception 'FALLA: se entregó sin acta';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    perform public.submit_handover(bid, 'entrega', 12000, 100, 'ok', array['otra-reserva/foto.jpg']);
    raise exception 'FALLA: aceptó fotos de otra carpeta';
  exception when invalid_parameter_value then null; end;
  perform public.submit_handover(bid, 'entrega', 12000, 100, 'Sin daños', array[bid::text || '/frente.jpg']);
  perform public.transition_booking(bid, 'en_curso');
  begin
    perform public.transition_booking(bid, 'devuelta');
    raise exception 'FALLA: se marcó devuelto sin acta';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
end $$;
reset role;

-- El arrendatario también registra su observación y ve el acta
select pg_temp.as_user('40000000-0000-0000-0000-00000000000b');
set role authenticated;
select public.submit_handover(current_setting('rue.t5')::uuid, 'devolucion', 12400, 80, 'Rayón previo en el estanque', '{}') is not null;
do $$ begin
  if (select count(*) from public.booking_handovers where booking_id = current_setting('rue.t5')::uuid) <> 2 then
    raise exception 'FALLA: el arrendatario no ve las actas';
  end if;
end $$;
reset role;

-- ------------------------------------------------ Cambiar la patente quita la verificación
select pg_temp.as_user('40000000-0000-0000-0000-00000000000a');
set role authenticated;
update public.vehicles set plate = 'ZZZZ99' where id = '50000000-0000-0000-0000-000000000001';
reset role;
do $$ begin
  if (select verified from public.vehicles where id = '50000000-0000-0000-0000-000000000001') then
    raise exception 'FALLA: cambiar la patente no quitó la verificación';
  end if;
  if exists (select 1 from public.search_vehicles() where id = '50000000-0000-0000-0000-000000000001') then
    raise exception 'FALLA: la búsqueda muestra un vehículo sin verificación vigente';
  end if;
end $$;

-- ------------------------------------------------ Vencimiento semestral
update public.vehicles set plate = 'ABCD12' where id = '50000000-0000-0000-0000-000000000001';
update public.vehicles set verified = true, verified_until = public.today_cl() - 1, status = 'publicado'
 where id = '50000000-0000-0000-0000-000000000001';
set role service_role;
do $$ begin
  if public.expire_vehicle_verifications() < 1 then raise exception 'FALLA: no venció la verificación'; end if;
end $$;
reset role;
do $$ begin
  if (select status from public.vehicles where id = '50000000-0000-0000-0000-000000000001') <> 'pausado' then
    raise exception 'FALLA: el vehículo vencido sigue publicado';
  end if;
  if not exists (select 1 from public.notifications where kind = 'vehicle_verification_expired') then
    raise exception 'FALLA: no se avisó el vencimiento';
  end if;
end $$;

-- ------------------------------------------------ Bitácora de datos: solo admin
select pg_temp.as_user('40000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$ begin
  begin
    insert into public.data_disclosures (booking_id, subject_user_id, recipient_name, recipient_role, data_shared, reason)
    values (current_setting('rue.t5')::uuid, '40000000-0000-0000-0000-00000000000b', 'Yo', 'arrendador', 'todo', 'porque sí');
    raise exception 'FALLA: un usuario registró una comunicación de datos';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

update public.platform_settings set value = 'false' where key = 'require_vehicle_verification';
select 'pruebas de cumplimiento de términos OK' as resultado;

-- ------------------------------------------------ 0006: horas del arrendador y casilla C obligatoria
insert into auth.users (id, email, raw_user_meta_data) values
  ('60000000-0000-0000-0000-00000000000a', 'o6@test.cl', '{"display_name":"Owner6"}'),
  ('60000000-0000-0000-0000-00000000000b', 'r6@test.cl', '{"display_name":"Renter6"}');
select pg_temp.as_user('60000000-0000-0000-0000-00000000000a');
set role authenticated;
insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp)
values ('70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-00000000000a', 'truck', 'publicado',
        'Camión 3/4 para mudanzas', 'Hyundai', 'HD65', 2020, 'Santiago', 60000);
reset role;

select pg_temp.as_user('60000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$ begin
  begin
    perform public.request_booking('70000000-0000-0000-0000-000000000001', public.today_cl() + 3, public.today_cl() + 5,
      p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => false);
    raise exception 'FALLA: permitió reservar sin la casilla C';
  exception when invalid_parameter_value then null; end;
  perform set_config('rue.t6', public.request_booking('70000000-0000-0000-0000-000000000001', public.today_cl() + 3, public.today_cl() + 5,
    p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);
end $$;
reset role;

select pg_temp.as_user('60000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.t6')::uuid; b public.bookings;
begin
  begin
    perform public.transition_booking(bid, 'aceptada');
    raise exception 'FALLA: se aceptó sin proponer horas';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  b := public.accept_booking(bid, '09:30', '19:00');
  if b.status <> 'aceptada' or b.pickup_time <> '09:30' or b.return_time <> '19:00' then
    raise exception 'FALLA: no quedaron las horas propuestas';
  end if;
end $$;
reset role;
do $$ begin
  if not exists (select 1 from public.notifications where booking_id = current_setting('rue.t6')::uuid
                 and kind = 'booking_accepted' and body like '%09:30%') then
    raise exception 'FALLA: el aviso no incluye la hora de entrega';
  end if;
end $$;

select pg_temp.as_user('60000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$ begin
  begin
    perform public.accept_booking(current_setting('rue.t6')::uuid, '08:00', '08:00');
    raise exception 'FALLA: el arrendatario pudo fijar las horas';
  exception when no_data_found or raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
end $$;
reset role;

set role service_role;
select pg_temp.as_user(null);
do $$ begin
  if public.confirm_booking_payment(current_setting('rue.t6')::uuid, 'mp-t6', 120000, 'test') <> 'confirmed' then
    raise exception 'FALLA: no se confirmó el pago t6';
  end if;
end $$;
reset role;
do $$ begin
  begin
    update public.bookings set pickup_time = '06:00' where id = current_setting('rue.t6')::uuid;
    raise exception 'FALLA: se cambiaron las horas de una reserva pagada';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
end $$;

select 'pruebas de horas y casilla C OK' as resultado;
