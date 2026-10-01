-- Pruebas de 0003/0004: legal, verificación, bloqueos, reportes, reseñas,
-- notificaciones, pagos no aprobados, pagos a propietarios y eliminar cuenta.
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

insert into auth.users (id, email, raw_user_meta_data) values
  ('20000000-0000-0000-0000-00000000000a', 'o2@test.cl', '{"display_name":"Owner2","terms_version":"2026-10-01"}'),
  ('20000000-0000-0000-0000-00000000000b', 'r2@test.cl', '{"display_name":"Renter2","terms_version":"2026-10-01"}'),
  ('20000000-0000-0000-0000-00000000000c', 'x2@test.cl', '{"display_name":"Tercero2"}'),
  ('20000000-0000-0000-0000-0000000000ad', 'admin@test.cl', '{"display_name":"Admin"}');
insert into public.admins (user_id) values ('20000000-0000-0000-0000-0000000000ad');
-- Este archivo usa comisión y cargo en 0 % (independiente de otras pruebas)
select set_config('request.jwt.claim.role', 'service_role', false);
select public.publish_economic_config('test-trust_safety', 0, 0, 2, 'Prueba trust_safety: sin comisiones');
select set_config('request.jwt.claim.role', '', false);

do $$ begin
  if (select count(*) from public.legal_acceptances where user_id in
      ('20000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000b')) <> 2 then
    raise exception 'FALLA: no se registró la aceptación de términos al registrarse';
  end if;
end $$;

-- Vehículo del owner2
select pg_temp.as_user('20000000-0000-0000-0000-00000000000a');
set role authenticated;
insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp)
values ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-00000000000a', 'car', 'publicado',
        'Yaris para apps', 'Toyota', 'Yaris', 2022, 'Santiago', 30000);
reset role;

-- ------------------------------------------------ Licencia obligatoria
update public.platform_settings set value = 'true' where key = 'require_verified_license';
select pg_temp.as_user('20000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$ begin
  begin
    perform public.request_booking('30000000-0000-0000-0000-000000000001', public.today_cl() + 1, public.today_cl() + 3, p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true);
    raise exception 'FALLA: permitió arrendar sin licencia verificada';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  perform public.submit_verification('license', '20000000-0000-0000-0000-00000000000b/licencia.jpg', null);
  begin
    perform public.submit_verification('license', '20000000-0000-0000-0000-00000000000c/ajena.jpg', null);
    raise exception 'FALLA: aceptó documentos de otra carpeta o duplicados';
  exception when raise_exception or check_violation then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    perform public.review_verification((select id from public.verification_requests limit 1), true);
    raise exception 'FALLA: un usuario normal pudo aprobar su verificación';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select pg_temp.as_user('20000000-0000-0000-0000-0000000000ad');
set role authenticated;
select public.review_verification((select id from public.verification_requests where kind = 'license' limit 1), true, null);
reset role;

-- ------------------------------------------------ Reserva completa con avisos y pago rechazado
select pg_temp.as_user('20000000-0000-0000-0000-00000000000b');
set role authenticated;
select set_config('rue.t2', public.request_booking('30000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2, p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);
reset role;

do $$ begin
  if not exists (select 1 from public.notifications where user_id = '20000000-0000-0000-0000-00000000000a' and kind = 'booking_requested') then
    raise exception 'FALLA: el propietario no recibió aviso de solicitud nueva';
  end if;
  if not exists (select 1 from public.notifications where user_id = '20000000-0000-0000-0000-00000000000b' and kind = 'verification') then
    raise exception 'FALLA: no se avisó la verificación aprobada';
  end if;
end $$;

select pg_temp.as_user('20000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.accept_booking(current_setting('rue.t2')::uuid, '10:00', '18:00') is not null;
insert into public.messages (booking_id, sender_id, body) values (current_setting('rue.t2')::uuid, auth.uid(), 'Hola');
insert into public.messages (booking_id, sender_id, body) values (current_setting('rue.t2')::uuid, auth.uid(), 'Hola de nuevo');
reset role;

do $$ begin
  if (select count(*) from public.notifications where user_id = '20000000-0000-0000-0000-00000000000b' and kind = 'message') <> 1 then
    raise exception 'FALLA: el aviso de mensajes no evita el spam';
  end if;
end $$;

set role service_role;
select pg_temp.as_user(null);
select public.record_payment_status(current_setting('rue.t2')::uuid, 'mp-900', 'rejected', 'cc_rejected_other_reason', 60000, 'test');
do $$ begin
  if public.confirm_booking_payment(current_setting('rue.t2')::uuid, 'mp-901', 60000, 'test') <> 'confirmed' then
    raise exception 'FALLA: no se confirmó el pago';
  end if;
end $$;
reset role;

do $$ begin
  if not exists (select 1 from public.notifications where kind = 'payment_failed') then
    raise exception 'FALLA: no se avisó el pago rechazado';
  end if;
  if (select status from public.payments where provider_payment_id = 'mp-900') <> 'rejected' then
    raise exception 'FALLA: no se registró el pago rechazado';
  end if;
end $$;

select pg_temp.as_user('20000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.t2')::uuid;
begin
  begin
    perform public.submit_review(bid, 5, 'Excelente');
    raise exception 'FALLA: permitió reseñar antes de terminar';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  perform public.submit_handover(bid, 'entrega', 1000, 100, 'ok', '{}');
  perform pg_temp.confirm_checkin(bid);
  perform public.transition_booking(bid, 'en_curso');
  perform public.submit_handover(bid, 'devolucion', 1300, 90, 'ok', '{}');
  perform public.transition_booking(bid, 'devuelta');
  perform public.transition_booking(bid, 'finalizada');
  perform public.submit_review(bid, 5, 'Excelente arrendatario');
  begin
    perform public.submit_review(bid, 4, 'otra');
    raise exception 'FALLA: permitió dos reseñas';
  exception when raise_exception then
    if sqlerrm like 'FALLA%' then raise; end if;
  end;
  if (select count(*) from public.payouts where booking_id = bid and amount_clp = 60000) <> 1 then
    raise exception 'FALLA: no se generó el pago pendiente al propietario';
  end if;
  if (public.user_reputation('20000000-0000-0000-0000-00000000000b') ->> 'rating_count')::int <> 1 then
    raise exception 'FALLA: la reputación no refleja la reseña';
  end if;
  if (select count(*) from public.my_bookings('owner')) <> 1 then
    raise exception 'FALLA: my_bookings no devuelve la reserva';
  end if;
end $$;

-- Datos bancarios: solo el dueño los ve
insert into public.payout_accounts (user_id, holder_name, holder_rut, bank, account_type, account_number)
values (auth.uid(), 'Owner Dos', '12345678-5', 'BancoEstado', 'rut', '12345678');
reset role;

select pg_temp.as_user('20000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$ begin
  if (select count(*) from public.payout_accounts) <> 0 then raise exception 'FALLA: se ven datos bancarios ajenos'; end if;
  if (select count(*) from public.payouts) <> 0 then raise exception 'FALLA: se ven pagos ajenos'; end if;
  if (select count(*) from public.notifications where user_id <> auth.uid()) <> 0 then raise exception 'FALLA: se ven avisos ajenos'; end if;
end $$;

-- ------------------------------------------------ Reportes y bloqueos
insert into public.reports (reporter_id, target_user_id, reason, details)
values (auth.uid(), '20000000-0000-0000-0000-00000000000a', 'acoso', 'prueba');
insert into public.user_blocks (blocker_id, blocked_id) values (auth.uid(), '20000000-0000-0000-0000-00000000000a');
do $$ begin
  if exists (select 1 from public.search_vehicles() where owner_id = '20000000-0000-0000-0000-00000000000a') then
    raise exception 'FALLA: se ven vehículos de un usuario bloqueado';
  end if;
  begin
    insert into public.messages (booking_id, sender_id, body) values (current_setting('rue.t2')::uuid, auth.uid(), 'x');
    raise exception 'FALLA: se pudo escribir con un bloqueo activo';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select pg_temp.as_user('20000000-0000-0000-0000-00000000000c');
set role authenticated;
do $$ begin
  if (select count(*) from public.reports) <> 0 then raise exception 'FALLA: un tercero ve reportes ajenos'; end if;
  begin
    insert into public.reports (reporter_id, target_user_id, reason) values ('20000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-00000000000a', 'otro');
    raise exception 'FALLA: se pudo reportar a nombre de otro';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ------------------------------------------------ Eliminar cuenta
set role service_role;
do $$ begin
  if public.delete_account_data('20000000-0000-0000-0000-00000000000b') <> 'ok' then
    raise exception 'FALLA: no pudo eliminar una cuenta sin reservas activas';
  end if;
end $$;
reset role;
do $$ begin
  if (select display_name from public.profiles where id = '20000000-0000-0000-0000-00000000000b') <> 'Usuario eliminado'
     or (select rut from public.profile_private where user_id = '20000000-0000-0000-0000-00000000000b') is not null then
    raise exception 'FALLA: la cuenta eliminada no quedó anonimizada';
  end if;
  if (select count(*) from public.bookings where id = current_setting('rue.t2')::uuid) <> 1 then
    raise exception 'FALLA: se borró el historial contable de la reserva';
  end if;
end $$;

-- Push: sin supabase_url configurada no falla nada
do $$ begin
  if (select value #>> '{}' from public.platform_settings where key = 'internal_webhook_secret') is null then
    raise exception 'FALLA: no se generó el secreto interno';
  end if;
end $$;

select 'pruebas de confianza y seguridad OK' as resultado;
