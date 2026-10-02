-- =============================================================================
-- RUÉ · 0011 · Buscar vehículos cerca de mí (sin revelar dónde vive el dueño)
--
--   * vehicle_locations: punto APROXIMADO del lugar de entrega, opcional, que el
--     propietario marca con su teléfono. El servidor lo redondea a una cuadrícula
--     de 0,01° (~1,1 km) y NADIE lo puede leer, ni siquiera desde la app: solo la
--     función de búsqueda lo usa para calcular distancias.
--   * search_vehicles(..., p_near_lat, p_near_lng, p_radius_km): devuelve
--     distance_km (entero, mínimo 1) y ordena por cercanía. Nunca coordenadas.
--     La ubicación de quien busca no se guarda (ni en domain_events).
--   * delete_account_data borra también los puntos aproximados del usuario.
-- =============================================================================

create table if not exists public.vehicle_locations (
  vehicle_id  uuid primary key references public.vehicles (id) on delete cascade,
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  lat         numeric(6,2) not null check (lat between -90 and 90),
  lng         numeric(6,2) not null check (lng between -180 and 180),
  updated_at  timestamptz not null default now()
);

alter table public.vehicle_locations enable row level security;
-- Sin policies: nadie la lee ni escribe directo. Solo las funciones de abajo.
revoke all on public.vehicle_locations from anon, authenticated;

-- El propietario marca (o actualiza) el punto aproximado de su vehículo.
create or replace function public.set_vehicle_location(p_vehicle_id uuid, p_lat double precision, p_lng double precision)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v public.vehicles%rowtype;
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found or v.owner_id is distinct from auth.uid() then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Ubicación no válida' using errcode = '22023';
  end if;
  -- Redondeo a ~1 km: el punto exacto nunca se guarda.
  insert into public.vehicle_locations (vehicle_id, owner_id, lat, lng)
  values (v.id, v.owner_id, round(p_lat::numeric, 2), round(p_lng::numeric, 2))
  on conflict (vehicle_id) do update set lat = excluded.lat, lng = excluded.lng, updated_at = now();
end;
$$;

create or replace function public.clear_vehicle_location(p_vehicle_id uuid)
returns void
language sql
volatile
security definer
set search_path = public
as $$
  delete from public.vehicle_locations where vehicle_id = p_vehicle_id and owner_id = auth.uid()
$$;

-- ¿Mi vehículo tiene punto aproximado? (solo el propietario; no devuelve coordenadas)
create or replace function public.vehicle_has_location(p_vehicle_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.vehicle_locations where vehicle_id = p_vehicle_id and owner_id = auth.uid())
$$;

-- Distancia en km entre dos puntos (fórmula del haversine).
create or replace function public.distance_km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision
language sql
immutable
as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

-- Búsqueda (reemplaza la de 0008): agrega cercanía. Cambia las columnas → se recrea.
drop function if exists public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int);

create function public.search_vehicles(
  p_type      public.vehicle_type default null,
  p_city      text default null,
  p_start     date default null,
  p_end       date default null,
  p_purpose   public.booking_purpose default null,
  p_limit     int default 20,
  p_offset    int default 0,
  p_near_lat  double precision default null,
  p_near_lng  double precision default null,
  p_radius_km int default null
)
returns table (
  id               uuid,
  owner_id         uuid,
  owner_name       text,
  vehicle_type     public.vehicle_type,
  title            text,
  brand            text,
  model            text,
  year             int,
  city             text,
  comuna           text,
  attributes       jsonb,
  use_cases        public.booking_purpose[],
  daily_price_clp  int,
  weekly_price_clp int,
  min_days         int,
  verified         boolean,
  cover_path       text,
  distance_km      int
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n int;
  near boolean := p_near_lat is not null and p_near_lng is not null
                  and p_near_lat between -90 and 90 and p_near_lng between -180 and 180;
  radius int := least(greatest(coalesce(p_radius_km, 50), 1), 500);
begin
  return query
  select
    v.id, v.owner_id, p.display_name, v.vehicle_type, v.title, v.brand, v.model, v.year,
    v.city, v.comuna, v.attributes, v.use_cases, v.daily_price_clp, v.weekly_price_clp,
    v.min_days, v.verified,
    (select ph.storage_path from public.vehicle_photos ph
      where ph.vehicle_id = v.id order by ph.position, ph.created_at limit 1),
    case when near and l.vehicle_id is not null
         then greatest(1, round(public.distance_km(p_near_lat, p_near_lng, l.lat::float8, l.lng::float8)))::int end
  from public.vehicles v
  join public.profiles p on p.id = v.owner_id
  left join public.vehicle_locations l on l.vehicle_id = v.id
  where v.status = 'publicado'
    and (
      not coalesce((select (s.value #>> '{}')::boolean from public.platform_settings s where s.key = 'require_vehicle_verification'), false)
      or (v.verified and v.verified_until >= public.today_cl())
    )
    and (auth.uid() is null or not public.is_blocked_between(auth.uid(), v.owner_id))
    and (p_type is null or v.vehicle_type = p_type)
    and (p_city is null or btrim(p_city) = ''
         or v.city ilike '%' || btrim(p_city) || '%' or v.comuna ilike '%' || btrim(p_city) || '%')
    and (p_purpose is null or cardinality(v.use_cases) = 0 or p_purpose = any (v.use_cases))
    and (
      p_start is null or p_end is null or p_end <= p_start
      or ((p_end - p_start) >= v.min_days and public.vehicle_is_available(v.id, p_start, p_end))
    )
    -- Cerca de mí: solo vehículos con punto aproximado dentro del radio.
    and (not near or (l.vehicle_id is not null
         and public.distance_km(p_near_lat, p_near_lng, l.lat::float8, l.lng::float8) <= radius))
  order by
    case when near then public.distance_km(p_near_lat, p_near_lng, l.lat::float8, l.lng::float8) end asc nulls last,
    v.verified desc, v.created_at desc
  limit least(greatest(p_limit, 1), 50)
  offset greatest(p_offset, 0);

  get diagnostics n = row_count;
  if coalesce(p_offset, 0) = 0 then
    -- Sin coordenadas: solo si se usó "cerca de mí" y el radio.
    perform public.emit_domain_event('search_performed', null, null, jsonb_build_object(
      'vehicle_type', p_type, 'city', nullif(lower(btrim(p_city)), ''), 'purpose', p_purpose,
      'start_date', p_start, 'end_date', p_end, 'result_count', n, 'zero_result', n = 0,
      'near_me', near, 'radius_km', case when near then radius end));
  end if;
end;
$$;

-- Eliminar cuenta (reemplaza la de 0003): además borra los puntos aproximados.
create or replace function public.delete_account_data(p_user_id uuid)
returns text   -- 'ok' | 'active_bookings'
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.bookings
    where (owner_id = p_user_id or renter_id = p_user_id)
      and status in ('confirmada', 'en_curso', 'devuelta', 'disputada')
  ) then
    return 'active_bookings';
  end if;

  perform set_config('rue.transition_note', 'Cuenta eliminada', true);
  update public.bookings set status = 'cancelada', cancelled_by = p_user_id, expires_at = null
   where (owner_id = p_user_id or renter_id = p_user_id) and status in ('solicitada', 'aceptada');
  perform set_config('rue.transition_note', '', true);

  delete from public.vehicle_locations where owner_id = p_user_id;
  delete from public.vehicles v
   where v.owner_id = p_user_id and not exists (select 1 from public.bookings b where b.vehicle_id = v.id);
  update public.vehicles set status = 'pausado', description = null where owner_id = p_user_id;

  update public.profiles
     set display_name = 'Usuario eliminado', avatar_url = null, bio = null, city = null
   where id = p_user_id;
  update public.profile_private
     set rut = null, phone = null, birth_date = null, address = null
   where user_id = p_user_id;
  delete from public.payout_accounts where user_id = p_user_id;
  delete from public.push_tokens where user_id = p_user_id;
  delete from public.verification_requests where user_id = p_user_id;
  delete from public.notifications where user_id = p_user_id;
  delete from public.user_blocks where blocker_id = p_user_id or blocked_id = p_user_id;
  return 'ok';
end;
$$;

revoke execute on function public.set_vehicle_location(uuid, double precision, double precision) from public, anon;
revoke execute on function public.clear_vehicle_location(uuid) from public, anon;
revoke execute on function public.vehicle_has_location(uuid) from public, anon;
revoke execute on function public.distance_km(double precision, double precision, double precision, double precision) from public, anon;
revoke execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int, double precision, double precision, int) from public, anon;
revoke execute on function public.delete_account_data(uuid) from public, anon, authenticated;

grant execute on function public.set_vehicle_location(uuid, double precision, double precision) to authenticated;
grant execute on function public.clear_vehicle_location(uuid) to authenticated;
grant execute on function public.vehicle_has_location(uuid) to authenticated;
grant execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int, double precision, double precision, int) to authenticated;
grant execute on function public.delete_account_data(uuid) to service_role;
