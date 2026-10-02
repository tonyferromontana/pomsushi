-- Pruebas de 0011: buscar cerca de mí sin revelar la ubicación del propietario.
\set ON_ERROR_STOP 1

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false);
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('c0000000-0000-0000-0000-00000000000a', 'near-owner@test.cl',  '{"display_name":"Dueño Cerca"}'),
  ('c0000000-0000-0000-0000-00000000000b', 'near-renter@test.cl', '{"display_name":"Arrendataria Cerca"}');
update public.platform_settings set value = 'false' where key in ('require_verified_license', 'require_vehicle_verification');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000a');
set role authenticated;
insert into public.vehicles (id, owner_id, vehicle_type, status, title, brand, model, year, city, daily_price_clp) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-00000000000a', 'van', 'publicado', 'Van Providencia', 'Kia', 'Pregio', 2019, 'Santiago', 40000),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-00000000000a', 'van', 'publicado', 'Van sin punto', 'Kia', 'Pregio', 2019, 'Santiago', 40000);
-- Punto exacto que manda el teléfono; se debe guardar redondeado (~1 km)
select public.set_vehicle_location('c1000000-0000-0000-0000-000000000001', -33.437218, -70.650612);
do $$ begin
  if not public.vehicle_has_location('c1000000-0000-0000-0000-000000000001') then
    raise exception 'FALLA: el dueño no ve que su vehículo tiene punto';
  end if;
  begin
    perform 1 from public.vehicle_locations;
    raise exception 'FALLA: se puede leer la tabla de ubicaciones';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

do $$ begin
  if (select lat::text || ',' || lng::text from public.vehicle_locations where vehicle_id = 'c1000000-0000-0000-0000-000000000001') <> '-33.44,-70.65' then
    raise exception 'FALLA: la ubicación no quedó redondeada';
  end if;
end $$;

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000b');
set role authenticated;
do $$
declare r record; n int;
begin
  begin
    perform public.set_vehicle_location('c1000000-0000-0000-0000-000000000001', 0, 0);
    raise exception 'FALLA: otra persona movió el punto de un vehículo ajeno';
  exception when no_data_found then null; end;
  if public.vehicle_has_location('c1000000-0000-0000-0000-000000000001') then
    raise exception 'FALLA: un tercero puede saber si el vehículo tiene punto';
  end if;
  begin
    perform 1 from public.vehicle_locations;
    raise exception 'FALLA: un tercero lee ubicaciones';
  exception when insufficient_privilege then null; end;

  -- Busco cerca de Plaza Italia (a ~2 km): solo aparece el vehículo con punto, con distancia entera
  select count(*) into n from public.search_vehicles(p_type => 'van', p_near_lat => -33.4372, p_near_lng => -70.6340, p_radius_km => 10)
   where id::text like 'c1000000%';
  if n <> 1 then raise exception 'FALLA: cerca de mí devolvió % vehículos', n; end if;
  select * into r from public.search_vehicles(p_type => 'van', p_near_lat => -33.4372, p_near_lng => -70.6340, p_radius_km => 10)
   where id = 'c1000000-0000-0000-0000-000000000001';
  if r.distance_km is null or r.distance_km not between 1 and 3 then
    raise exception 'FALLA: distancia inesperada %', r.distance_km;
  end if;
  -- Lejos (Valparaíso): no aparece
  select count(*) into n from public.search_vehicles(p_near_lat => -33.0472, p_near_lng => -71.6127, p_radius_km => 20)
   where id::text like 'c1000000%';
  if n <> 0 then raise exception 'FALLA: apareció un vehículo fuera del radio'; end if;
  -- Sin cerca de mí: aparecen ambos y sin distancia
  select count(*) into n from public.search_vehicles(p_type => 'van') where id::text like 'c1000000%' and distance_km is null;
  if n <> 2 then raise exception 'FALLA: la búsqueda normal cambió (%)', n; end if;
end $$;
reset role;

do $$ begin
  if exists (select 1 from public.domain_events where event_type = 'search_performed'
             and (payload ? 'lat' or payload ? 'lng' or payload::text like '%-33.43%')) then
    raise exception 'FALLA: se guardó la ubicación de quien busca';
  end if;
  if not exists (select 1 from public.domain_events where event_type = 'search_performed' and (payload ->> 'near_me')::boolean) then
    raise exception 'FALLA: no se registró que se usó cerca de mí';
  end if;
end $$;

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000a');
set role authenticated;
select public.clear_vehicle_location('c1000000-0000-0000-0000-000000000001');
do $$ begin
  if public.vehicle_has_location('c1000000-0000-0000-0000-000000000001') then raise exception 'FALLA: no se quitó el punto'; end if;
end $$;
reset role;

select 'pruebas de cerca de mí OK' as resultado;
