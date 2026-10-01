-- Pruebas de la configuración económica (0008): comisiones versionadas, garantías
-- de RUÉ, snapshot por reserva, ledger, GMV / take rate, payouts T+2 y eventos.
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
create or replace function pg_temp.as_server(p boolean) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.role', case when p then 'service_role' else '' end, false);
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e0000000-0000-0000-0000-00000000000a', 'eco-owner@test.cl',  '{"display_name":"Dueño Eco"}'),
  ('e0000000-0000-0000-0000-00000000000b', 'eco-renter@test.cl', '{"display_name":"Arrendataria Eco"}');

update public.platform_settings set value = 'false' where key in ('require_verified_license', 'require_vehicle_verification');

-- ---------------------------------------------------------------- Valores sembrados
do $$
declare c public.economic_config_versions;
begin
  select * into c from public.economic_config_versions where version = 'mvp-2026-10-01';
  if c.owner_fee_rate <> 0.15 or c.renter_service_fee_rate <> 0.08 or c.tax_treatment <> 'pending_accountant'
     or c.payout_delay_business_days <> 2 then
    raise exception 'FALLA: la configuración MVP no es 15 %% / 8 %% / IVA pendiente / T+2 (%)', row_to_json(c);
  end if;
  if exists (select 1 from public.platform_settings where key in ('owner_commission_pct', 'renter_service_fee_pct')) then
    raise exception 'FALLA: siguen existiendo comisiones en platform_settings (dos fuentes de verdad)';
  end if;
  if (select count(*) from public.platform_settings_history) = 0 then
    raise exception 'FALLA: los cambios de platform_settings no quedan auditados';
  end if;
  if (select jsonb_object_agg(vehicle_type, amount_clp) from public.guarantee_rules where version = 'mvp-2026-10-01')
     <> '{"motorcycle":150000,"car":250000,"suv":350000,"pickup":350000,"van":450000,"cargo_van":450000,
          "minibus":600000,"truck":800000,"trailer":800000,"special":800000}'::jsonb then
    raise exception 'FALLA: montos de garantía sembrados incorrectos';
  end if;
  -- Inmutables
  begin
    update public.economic_config_versions set owner_fee_rate = 0.5 where version = 'mvp-2026-10-01';
    raise exception 'FALLA: se pudo editar una versión publicada';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
  begin
    delete from public.guarantee_rules where vehicle_type = 'car';
    raise exception 'FALLA: se pudo borrar una regla de garantía';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
  -- La garantía nunca puede marcarse como ingreso
  begin
    insert into public.ledger_entries (entry_type, gross_amount_clp, counts_as_revenue, idempotency_key)
    values ('guarantee_capture', 1000, true, 'x');
    raise exception 'FALLA: la garantía se pudo registrar como ingreso';
  exception when check_violation then null; end;
  -- Días hábiles: viernes 2-oct-2026 + 2 = martes 6-oct; jueves 17-sep + 2 salta 18 y 19 (feriados) y el fin de semana
  if public.add_business_days('2026-10-02', 2) <> '2026-10-06' or public.add_business_days('2026-09-17', 2) <> '2026-09-22' then
    raise exception 'FALLA: cálculo de días hábiles';
  end if;
end $$;

-- Configuración de esta prueba = la del MVP (15 % / 8 %)
select pg_temp.as_server(true);
select public.publish_economic_config('test-economics', 0.15, 0.08, 2, 'Prueba economics: igual al MVP');
select pg_temp.as_server(false);

-- ---------------------------------------------------------------- Propietario
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$ begin
  begin
    insert into public.vehicles (owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp, deposit_clp)
    values (auth.uid(), 'car', 'publicado', 'Con garantía propia', 'Kia', 'Rio', 2020, 'Talca', 100000, 10);
    raise exception 'FALLA: el propietario pudo definir la garantía';
  exception when insufficient_privilege then null; end;

  insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp)
  values ('e1000000-0000-0000-0000-000000000001', auth.uid(), 'car', 'publicado', 'Auto Eco', 'Kia', 'Rio', 2020, 'Talca', 100000);

  begin
    update public.vehicles set deposit_clp = 1 where id = 'e1000000-0000-0000-0000-000000000001';
    raise exception 'FALLA: el propietario pudo cambiar la garantía';
  exception when insufficient_privilege then null; end;

  begin
    perform public.publish_economic_config('hack', 0, 0, 0, 'sin comisión');
    raise exception 'FALLA: un usuario cambió las comisiones';
  exception when insufficient_privilege then null; end;

  begin
    perform public.publish_guarantee_rule('car', 0, 'hack', 'sin garantía');
    raise exception 'FALLA: un usuario cambió las garantías';
  exception when insufficient_privilege then null; end;

  begin
    perform 1 from public.ledger_entries;
    raise exception 'FALLA: un usuario lee el ledger';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.economic_config_versions;
    raise exception 'FALLA: un usuario lee la configuración económica';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.booking_financials;
    raise exception 'FALLA: un usuario lee los reportes financieros';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.domain_events;
    raise exception 'FALLA: un usuario lee los eventos';
  exception when insufficient_privilege then null; end;
  begin
    perform public.marketplace_summary(public.today_cl(), public.today_cl());
    raise exception 'FALLA: un usuario ve las métricas del marketplace';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ---------------------------------------------------------------- Arrendataria
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$
declare q jsonb; bid uuid; b public.bookings;
begin
  if public.guarantee_for_type('car') <> 250000 or public.guarantee_for_type('motorcycle') <> 150000 then
    raise exception 'FALLA: guarantee_for_type';
  end if;

  perform public.search_vehicles(p_city => 'ciudad-que-no-existe');
  perform public.search_vehicles(p_city => 'talca');
  perform public.log_event('vehicle_viewed', 'e1000000-0000-0000-0000-000000000001');
  begin
    perform public.log_event('payment_approved');
    raise exception 'FALLA: la app pudo inventar un evento financiero';
  exception when invalid_parameter_value then null; end;

  q := public.quote_booking('e1000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 1);
  if (q->>'rental_clp')::int <> 100000 or (q->>'renter_fee_clp')::int <> 8000
     or (q->>'total_clp')::int <> 108000 or (q->>'deposit_clp')::int <> 250000 then
    raise exception 'FALLA: cotización del ejemplo %', q;
  end if;

  bid := public.request_booking('e1000000-0000-0000-0000-000000000001', public.today_cl(), public.today_cl() + 1,
           p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true);
  select * into b from public.bookings where id = bid;
  if b.rental_clp <> 100000 or b.gmv_clp <> 100000 or b.owner_commission_clp <> 15000 or b.renter_fee_clp <> 8000
     or b.total_clp <> 108000 or b.owner_payout_clp <> 85000 or b.deposit_clp <> 250000
     or b.platform_gross_revenue_clp <> 23000 then
    raise exception 'FALLA: componentes de la reserva %', row_to_json(b);
  end if;
  if b.pricing_snapshot #>> '{economic_config,version}' <> 'test-economics'
     or (b.pricing_snapshot #>> '{economic_config,owner_fee_rate}')::numeric <> 0.15
     or b.pricing_snapshot #>> '{economic_config,tax_treatment}' <> 'pending_accountant'
     or (b.pricing_snapshot #>> '{guarantee,amount_clp}')::int <> 250000
     or b.guarantee_rule_id is null or b.economic_config_id is null then
    raise exception 'FALLA: snapshot incompleto %', b.pricing_snapshot;
  end if;
  perform set_config('rue.eco1', bid::text, false);
end $$;
reset role;

-- Cambiar la configuración NO altera reservas existentes
select pg_temp.as_server(true);
select public.publish_economic_config('test-economics-20', 0.20, 0.10, 2, 'Prueba: subir comisiones');
select pg_temp.as_server(false);
do $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = current_setting('rue.eco1')::uuid;
  if b.total_clp <> 108000 or b.owner_commission_clp <> 15000 or b.pricing_snapshot #>> '{economic_config,version}' <> 'test-economics' then
    raise exception 'FALLA: la reserva cambió con la configuración nueva';
  end if;
  begin
    update public.bookings set pricing_snapshot = '{}' where id = b.id;
    raise exception 'FALLA: se pudo modificar el snapshot';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
end $$;
select pg_temp.as_server(true);
select public.publish_economic_config('test-economics-back', 0.15, 0.08, 2, 'Prueba: volver al MVP');
select pg_temp.as_server(false);

-- ---------------------------------------------------------------- Aceptar y pagar
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.accept_booking(current_setting('rue.eco1')::uuid, '09:00', '19:00') is not null;
reset role;

select pg_temp.as_user(null);
select pg_temp.as_server(true);
select set_config('rue.sum0', public.marketplace_summary(public.today_cl(), public.today_cl())::text, false);
set role service_role;
select public.confirm_booking_payment(current_setting('rue.eco1')::uuid, 'eco-pay-1', 108000, 'test') = 'confirmed' as pagado;
reset role;
select set_config('rue.sum1', public.marketplace_summary(public.today_cl(), public.today_cl())::text, false);
select pg_temp.as_server(false);

do $$
declare
  bid uuid := current_setting('rue.eco1')::uuid;
  s0 jsonb := current_setting('rue.sum0')::jsonb;
  s1 jsonb := current_setting('rue.sum1')::jsonb;
  f record;
begin
  if (select jsonb_object_agg(entry_type, gross_amount_clp) from public.ledger_entries where booking_id = bid)
     <> '{"payment_received":108000,"rental_base":100000,"owner_fee":15000,"renter_service_fee":8000,"owner_payout_due":85000}'::jsonb then
    raise exception 'FALLA: partidas del ledger %', (select jsonb_object_agg(entry_type, gross_amount_clp) from public.ledger_entries where booking_id = bid);
  end if;
  if (select sum(gross_amount_clp) from public.ledger_entries where booking_id = bid and counts_as_gmv) <> 100000
     or (select sum(gross_amount_clp) from public.ledger_entries where booking_id = bid and counts_as_revenue) <> 23000 then
    raise exception 'FALLA: GMV o ingreso en el ledger';
  end if;
  if exists (select 1 from public.ledger_entries where booking_id = bid and (tax_amount_clp is not null or net_amount_clp is not null)) then
    raise exception 'FALLA: se inventó IVA con el tratamiento pendiente';
  end if;
  if (s1->>'gmv_clp')::bigint - (s0->>'gmv_clp')::bigint <> 100000
     or (s1->>'platform_gross_revenue_clp')::bigint - (s0->>'platform_gross_revenue_clp')::bigint <> 23000 then
    raise exception 'FALLA: el resumen no suma GMV 100.000 e ingreso 23.000 (% → %)', s0, s1;
  end if;
  if s1->>'effective_take_rate' is null or s1->'platform_net_revenue_clp' <> 'null'::jsonb then
    raise exception 'FALLA: take rate / ingreso neto en el resumen %', s1;
  end if;

  select * into f from public.booking_financials where booking_id = bid;
  if f.gmv_amount <> 100000 or f.charged_amount <> 108000 or f.guarantee_amount <> 250000
     or f.platform_gross_revenue <> 23000 or f.tax_amount is not null or f.platform_net_revenue is not null then
    raise exception 'FALLA: booking_financials %', row_to_json(f);
  end if;
  -- Take rate del ejemplo: 23.000 / 100.000 = 23 %
  if round(f.platform_gross_revenue::numeric / f.gmv_amount, 2) <> 0.23 then
    raise exception 'FALLA: take rate del ejemplo';
  end if;
  if not exists (select 1 from public.domain_events where booking_id = bid and event_type = 'booking_confirmed')
     or not exists (select 1 from public.domain_events where booking_id = bid and event_type = 'payment_approved') then
    raise exception 'FALLA: faltan eventos de confirmación/pago';
  end if;
end $$;

-- ---------------------------------------------------------------- Entrega, devolución y payout T+2
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000a');
set role authenticated;
do $$
declare bid uuid := current_setting('rue.eco1')::uuid; po public.payouts;
begin
  perform public.submit_handover(bid, 'entrega', 1000, 100, 'ok', '{}');
  perform pg_temp.confirm_checkin(bid);
  perform public.transition_booking(bid, 'en_curso');
  if exists (select 1 from public.payouts where booking_id = bid) then
    raise exception 'FALLA: se creó el payout antes de la devolución';
  end if;
  perform public.submit_handover(bid, 'devolucion', 1100, 90, 'ok', '{}');
  perform public.transition_booking(bid, 'devuelta');
  select * into po from public.payouts where booking_id = bid;   -- el propietario ve su payout
  if po.status <> 'pending' or po.amount_clp <> 85000 or po.eligible_on <= public.today_cl() then
    raise exception 'FALLA: payout al devolver %', row_to_json(po);
  end if;
  begin
    perform public.mark_payout_paid(po.id, 'x');
    raise exception 'FALLA: el propietario marcó su payout como pagado';
  exception when insufficient_privilege then null; end;
  perform set_config('rue.eco_po', po.id::text, false);
end $$;
reset role;

select pg_temp.as_server(true);
do $$
declare pid uuid := current_setting('rue.eco_po')::uuid;
begin
  if (select eligible_on from public.payouts where id = pid) <> public.add_business_days(public.today_cl(), 2) then
    raise exception 'FALLA: el payout no queda a T+2 días hábiles';
  end if;
  begin
    perform public.mark_payout_paid(pid, 'TRF-1');
    raise exception 'FALLA: se pagó antes de T+2';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
  if public.promote_eligible_payouts() <> 0 and (select status from public.payouts where id = pid) = 'eligible' then
    raise exception 'FALLA: quedó elegible antes de la fecha';
  end if;
end $$;
-- Simula que pasaron dos días hábiles
update public.payouts set eligible_on = public.today_cl() where id = current_setting('rue.eco_po')::uuid;
do $$ begin
  perform public.promote_eligible_payouts();
  if (select status from public.payouts where id = current_setting('rue.eco_po')::uuid) <> 'eligible' then
    raise exception 'FALLA: no pasó a elegible';
  end if;
end $$;
select pg_temp.as_server(false);

-- Disputa: retiene el payout
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.transition_booking(current_setting('rue.eco1')::uuid, 'disputada') is not null;
reset role;

select pg_temp.as_server(true);
do $$
declare pid uuid := current_setting('rue.eco_po')::uuid; bid uuid := current_setting('rue.eco1')::uuid;
begin
  if (select status || '/' || hold_reason from public.payouts where id = pid) <> 'held/open_dispute' then
    raise exception 'FALLA: la disputa no retuvo el payout';
  end if;
  begin
    perform public.mark_payout_paid(pid, 'TRF-1');
    raise exception 'FALLA: se pagó un payout retenido';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
  perform public.release_payout(pid, 'Disputa resuelta a favor del propietario');
  perform public.mark_payout_paid(pid, 'TRF-1');
  if (select status from public.payouts where id = pid) <> 'paid'
     or (select gross_amount_clp from public.ledger_entries where payout_id = pid and entry_type = 'owner_payout_paid') <> -85000 then
    raise exception 'FALLA: pago al propietario no registrado';
  end if;
  if (select count(distinct event_type) from public.domain_events where booking_id = bid
        and event_type in ('vehicle_returned', 'dispute_opened', 'payout_eligible', 'payout_held', 'payout_paid')) <> 5 then
    raise exception 'FALLA: eventos de devolución/disputa/payout';
  end if;
  if not exists (select 1 from public.domain_events where event_type = 'search_performed' and (payload->>'zero_result')::boolean)
     or not exists (select 1 from public.domain_events where event_type = 'vehicle_viewed' and source = 'client') then
    raise exception 'FALLA: no se registraron búsquedas sin resultado o vistas';
  end if;
end $$;
select pg_temp.as_server(false);

-- ---------------------------------------------------------------- Cancelación después del pago: reversa y reembolso
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000b');
set role authenticated;
select set_config('rue.eco2', public.request_booking('e1000000-0000-0000-0000-000000000001', public.today_cl() + 5, public.today_cl() + 7,
  p_terms_version => '2026-10-01', p_accept_terms => true, p_accept_data_sharing => true)::text, false);
reset role;
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.accept_booking(current_setting('rue.eco2')::uuid, '09:00', '19:00') is not null;
reset role;
select pg_temp.as_user(null);
set role service_role;
select public.confirm_booking_payment(current_setting('rue.eco2')::uuid, 'eco-pay-2', 216000, 'test') = 'confirmed' as pagado;
reset role;
update public.bookings set status = 'cancelada' where id = current_setting('rue.eco2')::uuid;   -- soporte
select pg_temp.as_server(true);
select public.record_manual_refund(current_setting('rue.eco2')::uuid, 216000, 'TBK-ANUL-1');
select public.record_manual_refund(current_setting('rue.eco2')::uuid, 216000, 'TBK-ANUL-1');  -- idempotente
select public.record_processing_cost(current_setting('rue.eco1')::uuid, 2000, 'Liquidación TBK 1');
do $$
declare bid uuid := current_setting('rue.eco2')::uuid; f record;
begin
  if (select sum(gross_amount_clp) from public.ledger_entries where booking_id = bid and counts_as_gmv) <> 0
     or (select sum(gross_amount_clp) from public.ledger_entries where booking_id = bid and counts_as_revenue) <> 0 then
    raise exception 'FALLA: la cancelación no revirtió GMV e ingreso';
  end if;
  select * into f from public.booking_financials where booking_id = bid;
  if f.refunds <> 216000 then raise exception 'FALLA: reembolso en booking_financials %', row_to_json(f); end if;
  select * into f from public.booking_financials where booking_id = current_setting('rue.eco1')::uuid;
  if f.payment_processing_cost <> 2000 or f.platform_net_revenue is not null then
    raise exception 'FALLA: costo de procesamiento / ingreso neto con IVA pendiente %', row_to_json(f);
  end if;
  begin
    delete from public.ledger_entries where booking_id = bid;
    raise exception 'FALLA: se pudo borrar el ledger';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if; end;
end $$;
select pg_temp.as_server(false);

-- Nueva regla de garantía: aplica a reservas nuevas, no a las anteriores
select pg_temp.as_server(true);
select public.publish_guarantee_rule('car', 300000, 'test-2', 'Prueba: subir garantía autos');
select pg_temp.as_server(false);
do $$ begin
  if public.guarantee_for_type('car') <> 300000 then raise exception 'FALLA: no tomó la regla nueva'; end if;
  if (select deposit_clp from public.bookings where id = current_setting('rue.eco1')::uuid) <> 250000 then
    raise exception 'FALLA: la garantía de una reserva existente cambió';
  end if;
end $$;
select pg_temp.as_server(true);
select public.publish_guarantee_rule('car', 250000, 'test-3', 'Prueba: volver al MVP');
select pg_temp.as_server(false);

select 'pruebas de economía OK' as resultado;
