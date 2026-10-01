-- Pruebas de 0009: negociación (ofertas y mínimo de RUÉ), datos de contacto,
-- contrato digital, check-in/out con confirmación, extensiones, trust y repetición.
\set ON_ERROR_STOP 1

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false);
end $$;
create or replace function pg_temp.as_server(p boolean) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.role', case when p then 'service_role' else '' end, false);
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('f0000000-0000-0000-0000-00000000000a', 'lc-owner@test.cl',  '{"display_name":"Dueña LC"}'),
  ('f0000000-0000-0000-0000-00000000000b', 'lc-renter@test.cl', '{"display_name":"Arrendatario LC"}'),
  ('f0000000-0000-0000-0000-00000000000c', 'lc-other@test.cl',  '{"display_name":"Otra LC"}');

update public.platform_settings set value = 'false' where key in ('require_verified_license', 'require_vehicle_verification');
select pg_temp.as_server(true);
select public.publish_economic_config('test-lifecycle', 0.15, 0.08, 2, 'Prueba lifecycle: igual al MVP');
select pg_temp.as_server(false);

-- ---------------------------------------------------------------- Publicación sin datos de contacto
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$ begin
  begin
    insert into public.vehicles (owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp, description)
    values (auth.uid(), 'car', 'publicado', 'Auto', 'Kia', 'Rio', 2020, 'Temuco', 55000, 'Llámame al +56 9 8765 4321');
    raise exception 'FALLA: se publicó un teléfono';
  exception when invalid_parameter_value then null; end;
  begin
    update public.profiles set bio = 'escríbeme a dueña@correo.cl' where id = auth.uid();
    raise exception 'FALLA: se puso un correo en el perfil';
  exception when invalid_parameter_value then null; end;

  insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp, km_per_day, description)
  values ('f1000000-0000-0000-0000-000000000001', auth.uid(), 'car', 'publicado', 'Auto LC', 'Kia', 'Rio', 2020, 'Temuco', 55000, 200,
          'Año 2020, 150.000 km, motor 1.600 cc');
end $$;
reset role;

-- ---------------------------------------------------------------- Guía de precio y ofertas
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$
declare q jsonb; bid uuid; b public.bookings; o public.booking_offers;
begin
  q := public.quote_booking('f1000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2);
  if (q->>'published_daily_clp')::int <> 55000 or (q->>'recommended_daily_low_clp')::int <> 52000
     or (q->>'recommended_daily_high_clp')::int <> 58000 or q ? 'minimum_clp' or (q->>'max_rounds')::int <> 3 then
    raise exception 'FALLA: guía de precio %', q;
  end if;
  begin
    perform public.quote_booking('f1000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2, 44000);
    raise exception 'FALLA: aceptó una oferta bajo el mínimo';
  exception when raise_exception then
    if sqlerrm <> 'Esta oferta está bajo el mínimo permitido.' then raise; end if;
  end;
  q := public.quote_booking('f1000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2, 45000);
  if (q->>'rental_clp')::int <> 90000 then raise exception 'FALLA: oferta en el mínimo %', q; end if;
  q := public.quote_booking('f1000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2, 70000);
  if q->'offer_daily_clp' <> 'null'::jsonb or (q->>'rental_clp')::int <> 110000 then
    raise exception 'FALLA: una oferta sobre el publicado debe ser el precio publicado %', q;
  end if;

  bid := public.request_booking('f1000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 2,
           p_message => 'Hola, mi whatsapp es +56 9 1234 5678', p_terms_version => '2026-10-01',
           p_accept_terms => true, p_accept_data_sharing => true, p_offer_daily_clp => 48000);
  select * into b from public.bookings where id = bid;
  select * into o from public.booking_offers where booking_id = bid;
  if b.rental_clp <> 96000 or (b.pricing_snapshot #>> '{negotiation,agreed_daily_clp}')::int <> 48000
     or o.status <> 'pending' or o.round_number <> 1 or o.amount_clp <> 48000 then
    raise exception 'FALLA: solicitud con oferta % / %', row_to_json(b), row_to_json(o);
  end if;
  if b.renter_message like '%1234%' then raise exception 'FALLA: el teléfono del mensaje no se ocultó'; end if;
  begin
    perform public.counter_offer(bid, 50000);
    raise exception 'FALLA: contraofertó su propia oferta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
  perform set_config('rue.lc1', bid::text, false);
end $$;
reset role;

-- Propietaria contraoferta (debe incluir horas)
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.lc1')::uuid;
begin
  begin
    perform public.counter_offer(bid, 52000);
    raise exception 'FALLA: contraoferta sin horas';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.counter_offer(bid, 40000, '09:00', '18:00');
    raise exception 'FALLA: contraoferta bajo el mínimo';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
  perform public.counter_offer(bid, 52000, '09:00', '18:00');
  begin
    perform public.accept_booking(bid, '09:00', '18:00');
    raise exception 'FALLA: aceptó mientras esperaba respuesta a su contraoferta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
end $$;
reset role;

-- Arrendatario contraoferta (ronda 3)
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
select public.counter_offer(current_setting('rue.lc1')::uuid, 50000) is not null;
reset role;

-- Propietaria: ya no puede contraofertar (máximo 3 rondas); acepta 50.000
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.lc1')::uuid; b public.bookings;
begin
  begin
    perform public.counter_offer(bid, 51000, '09:00', '18:00');
    raise exception 'FALLA: superó el máximo de rondas';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
  b := public.accept_booking(bid, '10:00', '19:00');
  if b.status <> 'aceptada' or b.rental_clp <> 100000 or b.owner_commission_clp <> 15000 or b.renter_fee_clp <> 8000
     or b.total_clp <> 108000 or (b.pricing_snapshot #>> '{negotiation,accepted_round}')::int <> 3
     or (b.pricing_snapshot #>> '{negotiation,agreed_daily_clp}')::int <> 50000 then
    raise exception 'FALLA: aceptación con precio negociado %', row_to_json(b);
  end if;
  if (select string_agg(status, ',' order by round_number) from public.booking_offers where booking_id = bid) <> 'countered,countered,accepted' then
    raise exception 'FALLA: historial de ofertas';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------- Chat: datos ocultos antes de pagar
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
insert into public.messages (booking_id, sender_id, body) values
  (current_setting('rue.lc1')::uuid, auth.uid(), 'Escríbeme al +56 9 1234 5678 o a juan@correo.cl'),
  (current_setting('rue.lc1')::uuid, auth.uid(), 'Mejor págame afuera por transferencia y te hago descuento'),
  (current_setting('rue.lc1')::uuid, auth.uid(), 'Nos vemos a las 10 en el metro, año 2020 y 150.000 km');
do $$ begin
  if exists (select 1 from public.messages where body like '%5678%' or body like '%juan@%') then
    raise exception 'FALLA: el chat mostró datos de contacto antes de confirmar';
  end if;
  if (select count(*) from public.messages where booking_id = current_setting('rue.lc1')::uuid and moderation is not null) <> 2 then
    raise exception 'FALLA: moderación (debían marcarse 2 de 3 mensajes)';
  end if;
  begin
    perform 1 from public.message_flags;
    raise exception 'FALLA: un usuario lee las marcas de moderación';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  if (select count(*) from public.message_flags where booking_id = current_setting('rue.lc1')::uuid) <> 3   -- 2 chat + 1 solicitud
     or not exists (select 1 from public.message_flags where 'off_platform_payment' = any (signals) and not masked) then
    raise exception 'FALLA: marcas para revisión %', (select json_agg(m) from public.message_flags m);
  end if;
end $$;

-- ---------------------------------------------------------------- Pago → contrato digital
select pg_temp.as_user(null);
set role service_role;
select public.confirm_booking_payment(current_setting('rue.lc1')::uuid, 'lc-pay-1', 108000, 'test') = 'confirmed' as pagado;
reset role;

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000c');
set role authenticated;
do $$ begin
  if exists (select 1 from public.booking_agreements) or exists (select 1 from public.booking_offers) then
    raise exception 'FALLA: un tercero ve contratos u ofertas ajenas';
  end if;
  if (public.vehicle_trust('f1000000-0000-0000-0000-000000000001')) ? 'utilization_90d' then
    raise exception 'FALLA: un tercero ve la utilización del vehículo';
  end if;
  if (public.user_trust('f0000000-0000-0000-0000-00000000000a')) ? 'disputes' then
    raise exception 'FALLA: trust expone disputas';
  end if;
end $$;
reset role;

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.lc1')::uuid; a public.booking_agreements;
begin
  select * into a from public.booking_agreements where booking_id = bid and version = 1;
  if a.kind <> 'contract' or length(a.content_sha256) <> 64 or (a.content #>> '{economics,charged_clp}')::int <> 108000
     or (a.content #>> '{economics,guarantee_clp}')::int <> 250000 or a.content #>> '{protection,status}' <> 'not_offered' then
    raise exception 'FALLA: contrato digital %', row_to_json(a);
  end if;
  -- Después de confirmar, compartir un teléfono para coordinar la entrega es normal
  insert into public.messages (booking_id, sender_id, body) values (bid, auth.uid(), 'Mi número es +56 9 1234 5678');
  if not exists (select 1 from public.messages where booking_id = bid and body like '%5678%') then
    raise exception 'FALLA: se ocultó el teléfono después de confirmar';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------- Check-in con confirmación de ambos
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.lc1')::uuid;
begin
  begin
    perform public.submit_handover(bid, 'entrega', 50000, 100, 'ok', '{}', '[{"zona":"x"}]');
    raise exception 'FALLA: aceptó daños con formato inválido';
  exception when check_violation then null; end;
  perform public.submit_handover(bid, 'entrega', 50000, 100, 'Rayón previo', '{}',
                                 '[{"zone":"Parachoques trasero","description":"rayón leve"}]');
  begin
    perform public.transition_booking(bid, 'en_curso');
    raise exception 'FALLA: inició sin que el arrendatario confirmara el acta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
end $$;
reset role;

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
select public.confirm_handover((select id from public.booking_handovers where booking_id = current_setting('rue.lc1')::uuid and kind = 'entrega'));
reset role;

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
select (public.transition_booking(current_setting('rue.lc1')::uuid, 'en_curso')).status = 'en_curso' as en_curso;
reset role;

-- ---------------------------------------------------------------- Extensión
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.lc1')::uuid; eid uuid; e public.booking_extensions;
begin
  begin
    perform public.request_extension(bid, public.today_cl() + 1);
    raise exception 'FALLA: extensión hacia atrás';
  exception when invalid_parameter_value then null; end;
  eid := public.request_extension(bid, public.today_cl() + 4);
  select * into e from public.booking_extensions where id = eid;
  if e.status <> 'pending_owner' or e.days <> 2 or e.daily_rate_clp <> 50000 or e.rental_clp <> 100000
     or e.renter_fee_clp <> 8000 or e.total_clp <> 108000 or e.owner_payout_clp <> 85000 then
    raise exception 'FALLA: extensión mal calculada %', row_to_json(e);
  end if;
  begin
    perform public.respond_extension(eid, true);
    raise exception 'FALLA: el arrendatario aprobó su propia extensión';
  exception when no_data_found then null; end;
  perform set_config('rue.lc_ext', eid::text, false);
end $$;
reset role;

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.respond_extension(current_setting('rue.lc_ext')::uuid, true);
reset role;

select pg_temp.as_user(null);
set role service_role;
do $$
declare eid uuid := current_setting('rue.lc_ext')::uuid; bid uuid := current_setting('rue.lc1')::uuid;
begin
  if public.confirm_extension_payment(eid, 'lc-ext-0', 1000, 'test') <> 'amount_mismatch' then raise exception 'FALLA: monto extensión'; end if;
  if public.confirm_extension_payment(eid, 'lc-ext-1', 108000, 'test') <> 'confirmed' then raise exception 'FALLA: no confirmó la extensión'; end if;
  if public.confirm_extension_payment(eid, 'lc-ext-1', 108000, 'test') <> 'already_confirmed' then raise exception 'FALLA: extensión no idempotente'; end if;
  if (select end_date from public.bookings where id = bid) <> public.today_cl() + 4 then
    raise exception 'FALLA: la reserva no se extendió';
  end if;
  if (select total_clp from public.bookings where id = bid) <> 108000 then
    raise exception 'FALLA: la extensión modificó los montos originales de la reserva';
  end if;
end $$;
reset role;
do $$
declare bid uuid := current_setting('rue.lc1')::uuid;
begin
  if (select sum(gross_amount_clp) from public.ledger_entries where booking_id = bid and counts_as_gmv) <> 200000
     or (select sum(gross_amount_clp) from public.ledger_entries where booking_id = bid and counts_as_revenue) <> 46000 then
    raise exception 'FALLA: ledger con extensión';
  end if;
  if (select count(*) from public.booking_agreements where booking_id = bid) <> 2
     or not exists (select 1 from public.booking_agreements where booking_id = bid and kind = 'extension_addendum') then
    raise exception 'FALLA: falta el anexo de extensión';
  end if;
  if (select extension_gmv_amount from public.booking_financials where booking_id = bid) <> 100000 then
    raise exception 'FALLA: booking_financials sin extensión';
  end if;
end $$;

-- ---------------------------------------------------------------- Check-out, comparación y payout
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.lc1')::uuid; c jsonb;
begin
  perform public.submit_handover(bid, 'devolucion', 50750, 60, 'Golpe nuevo', '{}',
                                 '[{"zone":"Parachoques trasero","description":"rayón leve"},{"zone":"Puerta derecha","description":"abolladura"}]');
  perform public.transition_booking(bid, 'devuelta');
  c := public.handover_comparison(bid);
  if (c->>'km_driven')::int <> 750 or (c->>'fuel_delta')::int <> -40 or c->'new_damage_zones' <> '["Puerta derecha"]'::jsonb
     or (c->>'km_allowed')::int <> 800 then
    raise exception 'FALLA: comparación antes/después %', c;
  end if;
  if (select amount_clp from public.payouts where booking_id = bid) <> 170000 then
    raise exception 'FALLA: el payout no incluye la extensión';
  end if;
  if not (public.vehicle_trust('f1000000-0000-0000-0000-000000000001') ? 'utilization_90d') then
    raise exception 'FALLA: la propietaria no ve la utilización';
  end if;
  perform public.transition_booking(bid, 'finalizada');
end $$;
reset role;

-- ---------------------------------------------------------------- Aceptar la contraoferta y relación repetida
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
select set_config('rue.lc2', public.request_booking('f1000000-0000-0000-0000-000000000001', public.today_cl() + 10, public.today_cl() + 12,
  p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true, p_offer_daily_clp => 46000)::text, false);
reset role;
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.counter_offer(current_setting('rue.lc2')::uuid, 53000, '08:00', '20:00') is not null;
reset role;
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$
declare b public.bookings;
begin
  b := public.accept_offer(current_setting('rue.lc2')::uuid);
  if b.status <> 'aceptada' or b.rental_clp <> 106000 or b.pickup_time <> '08:00' or b.return_time <> '20:00' then
    raise exception 'FALLA: aceptar contraoferta %', row_to_json(b);
  end if;
  if (b.pricing_snapshot #>> '{relationship,repeat_pair_completed}')::int <> 1 then
    raise exception 'FALLA: no se registró que la pareja ya completó un arriendo';
  end if;
end $$;
reset role;

do $$ begin
  if (select count(distinct event_type) from public.domain_events
      where event_type in ('offer_made', 'offer_countered', 'offer_accepted', 'extension_requested', 'extension_paid',
                           'check_in_completed', 'agreement_generated', 'off_platform_signal')) <> 8 then
    raise exception 'FALLA: faltan eventos del ciclo de vida';
  end if;
end $$;

select 'pruebas del ciclo transaccional OK' as resultado;
