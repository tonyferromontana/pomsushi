-- =============================================================================
-- RUÉ · 0005 · Cumplimiento de los Términos y Condiciones (versión 2026-09-30)
--
--   Cláusula 4  → Verificación de dominio del vehículo: Certificado de Anotaciones
--                 Vigentes (≤ 30 días al cargarlo) + padrón. Vigencia 6 meses.
--                 Con `require_vehicle_verification` = true, solo se publican
--                 vehículos con verificación vigente.
--   Cláusula 4  → Ficha: patente, kilometraje permitido, lugar de entrega,
--                 combustible y seguro declarados en la publicación.
--   Cláusula 6/24 → Casillas por reserva (A términos, C comunicación de datos),
--                 con versión, fecha e identidad.
--   Cláusula 11 → Actas de entrega y devolución (km, combustible, observaciones,
--                 fotos). Sin acta no se puede marcar entregado ni devuelto.
--   Cláusula 18 → Bitácora de comunicaciones de datos a arrendadores/abogados.
-- =============================================================================

update public.platform_settings set value = '"2026-09-30"', updated_at = now() where key = 'terms_version';

insert into public.platform_settings (key, value, description) values
  ('require_vehicle_verification', 'false',
   'Si es true, solo se pueden publicar vehículos con Certificado de Anotaciones Vigentes verificado y no vencido (cláusula 4). Activar antes de lanzar.'),
  ('vehicle_verification_months', '6', 'Meses de vigencia de la verificación de dominio del vehículo.'),
  ('cav_max_age_days', '30', 'Antigüedad máxima del Certificado de Anotaciones Vigentes al cargarlo (días corridos).')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- Ficha del vehículo
-- -----------------------------------------------------------------------------

alter table public.vehicles add column if not exists plate text
  check (plate is null or plate ~ '^[A-Z]{2,4}[0-9]{2,4}$');
alter table public.vehicles add column if not exists km_per_day int
  check (km_per_day is null or km_per_day between 10 and 5000);
alter table public.vehicles add column if not exists pickup_location text
  check (char_length(pickup_location) <= 160);
alter table public.vehicles add column if not exists fuel_policy text not null default 'mismo_nivel'
  check (fuel_policy in ('mismo_nivel', 'lleno'));
alter table public.vehicles add column if not exists insurance_info text
  check (char_length(insurance_info) <= 500);
alter table public.vehicles add column if not exists verified_until date;

grant insert (plate, km_per_day, pickup_location, fuel_policy, insurance_info) on public.vehicles to authenticated;
grant update (plate, km_per_day, pickup_location, fuel_policy, insurance_info) on public.vehicles to authenticated;

-- -----------------------------------------------------------------------------
-- Verificación de dominio (Certificado de Anotaciones Vigentes + padrón)
-- -----------------------------------------------------------------------------

create table if not exists public.vehicle_verifications (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references public.vehicles (id) on delete cascade,
  owner_id      uuid not null references public.profiles (id) on delete cascade,
  cav_path      text not null,
  padron_path   text not null,
  cav_issued_on date not null,
  status        public.verification_status not null default 'pendiente',
  review_note   text check (char_length(review_note) <= 500),
  reviewed_by   uuid references auth.users (id),
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  constraint vehicle_verifications_paths_owned check (
    split_part(cav_path, '/', 1) = owner_id::text and split_part(padron_path, '/', 1) = owner_id::text
  )
);

create index if not exists vehicle_verifications_vehicle_idx on public.vehicle_verifications (vehicle_id, created_at desc);
create index if not exists vehicle_verifications_pending_idx on public.vehicle_verifications (status) where status = 'pendiente';

alter table public.vehicle_verifications enable row level security;

create policy "vehicle_verifications: el propietario ve las suyas"
  on public.vehicle_verifications for select to authenticated using (owner_id = auth.uid());
create policy "vehicle_verifications: administradores ven todas"
  on public.vehicle_verifications for select to authenticated using (public.is_admin());

revoke all on public.vehicle_verifications from anon;
revoke insert, update, delete on public.vehicle_verifications from authenticated;
grant select on public.vehicle_verifications to authenticated;

create or replace function public.submit_vehicle_verification(
  p_vehicle_id uuid, p_cav_path text, p_padron_path text, p_cav_issued_on date
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  max_age int := coalesce(public.setting_numeric('cav_max_age_days'), 30)::int;
  new_id uuid;
begin
  if uid is null then
    raise exception 'Tienes que iniciar sesión' using errcode = '42501';
  end if;
  if not exists (select 1 from public.vehicles where id = p_vehicle_id and owner_id = uid) then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;
  if p_cav_issued_on is null or p_cav_issued_on > public.today_cl() then
    raise exception 'Revisa la fecha de emisión del certificado' using errcode = '22023';
  end if;
  if public.today_cl() - p_cav_issued_on > max_age then
    raise exception 'El certificado debe tener máximo % días desde su emisión. Descarga uno nuevo en el Registro Civil.', max_age
      using errcode = '22023';
  end if;
  if exists (select 1 from public.vehicle_verifications where vehicle_id = p_vehicle_id and status = 'pendiente') then
    raise exception 'Este vehículo ya tiene una verificación en revisión' using errcode = 'P0001';
  end if;
  insert into public.vehicle_verifications (vehicle_id, owner_id, cav_path, padron_path, cav_issued_on)
  values (p_vehicle_id, uid, p_cav_path, p_padron_path, p_cav_issued_on)
  returning id into new_id;
  return new_id;
end;
$$;

-- Solo administradores. Al aprobar, el vehículo queda verificado por N meses desde hoy.
create or replace function public.review_vehicle_verification(p_request_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.vehicle_verifications%rowtype;
  months int := coalesce(public.setting_numeric('vehicle_verification_months'), 6)::int;
  vtitle text;
begin
  if not public.is_admin() and auth.role() is distinct from 'service_role' then
    raise exception 'Solo un administrador puede revisar verificaciones' using errcode = '42501';
  end if;
  select * into r from public.vehicle_verifications where id = p_request_id for update;
  if not found then
    raise exception 'Solicitud no encontrada' using errcode = 'P0002';
  end if;
  update public.vehicle_verifications
     set status = case when p_approve then 'aprobada'::public.verification_status else 'rechazada' end,
         review_note = p_note, reviewed_by = auth.uid(), reviewed_at = now()
   where id = r.id;
  select title into vtitle from public.vehicles where id = r.vehicle_id;
  if p_approve then
    perform set_config('rue.admin_vehicle_update', 'on', true);
    update public.vehicles
       set verified = true, verified_until = (public.today_cl() + make_interval(months => months))::date
     where id = r.vehicle_id;
    perform set_config('rue.admin_vehicle_update', '', true);
  end if;
  insert into public.notifications (user_id, kind, title, body)
  values (r.owner_id, 'vehicle_verification',
          case when p_approve then 'Vehículo verificado' else 'Revisa los documentos de tu vehículo' end,
          case when p_approve then coalesce(vtitle, 'Tu vehículo') || ' ya puede publicarse.'
               else coalesce(p_note, 'No pudimos validar los documentos. Vuelve a enviarlos.') end);
end;
$$;

-- Regla de publicación (cláusula 4): con la exigencia activa, solo vehículos verificados y vigentes.
create or replace function public.enforce_vehicle_publication()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'publicado'
     and (tg_op = 'INSERT' or old.status is distinct from 'publicado')
     and coalesce((select (value #>> '{}')::boolean from public.platform_settings where key = 'require_vehicle_verification'), false)
     and not (new.verified and new.verified_until is not null and new.verified_until >= public.today_cl()) then
    raise exception 'Para publicar, verifica tu vehículo con el Certificado de Anotaciones Vigentes y el padrón'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists vehicles_enforce_publication on public.vehicles;
create trigger vehicles_enforce_publication
  before insert or update of status on public.vehicles
  for each row execute function public.enforce_vehicle_publication();

-- Si cambian datos que identifican el vehículo, se pierde la verificación (hay que volver a acreditar dominio).
create or replace function public.reset_vehicle_verification()
returns trigger
language plpgsql
as $$
begin
  if current_setting('rue.admin_vehicle_update', true) = 'on' then
    return new;
  end if;
  if (new.plate, new.brand, new.model, new.year) is distinct from (old.plate, old.brand, old.model, old.year) then
    new.verified := false;
    new.verified_until := null;
  end if;
  return new;
end;
$$;

drop trigger if exists vehicles_reset_verification on public.vehicles;
create trigger vehicles_reset_verification
  before update on public.vehicles
  for each row execute function public.reset_vehicle_verification();

-- Vencimiento semestral (cron diario): quita la verificación, pausa nuevas reservas
-- (si la exigencia está activa) y avisa. Las reservas ya confirmadas siguen su curso.
create or replace function public.expire_vehicle_verifications()
returns int
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n int := 0;
  v record;
  enforce boolean := coalesce((select (value #>> '{}')::boolean from public.platform_settings where key = 'require_vehicle_verification'), false);
begin
  perform set_config('rue.admin_vehicle_update', 'on', true);
  for v in
    select id, owner_id, title from public.vehicles
    where verified and verified_until is not null and verified_until < public.today_cl()
  loop
    update public.vehicles
       set verified = false,
           status = case when enforce and status = 'publicado' then 'pausado'::public.listing_status else status end
     where id = v.id;
    insert into public.notifications (user_id, kind, title, body)
    values (v.owner_id, 'vehicle_verification_expired', 'Renueva el certificado de tu vehículo',
            'Sube un Certificado de Anotaciones Vigentes nuevo para ' || v.title || ' y sigue recibiendo reservas.');
    n := n + 1;
  end loop;
  perform set_config('rue.admin_vehicle_update', '', true);
  return n;
end;
$$;

-- La búsqueda respeta la exigencia de verificación (reemplaza la versión de 0003)
create or replace function public.search_vehicles(
  p_type    public.vehicle_type default null,
  p_city    text default null,
  p_start   date default null,
  p_end     date default null,
  p_purpose public.booking_purpose default null,
  p_limit   int default 20,
  p_offset  int default 0
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
  cover_path       text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    v.id, v.owner_id, p.display_name, v.vehicle_type, v.title, v.brand, v.model, v.year,
    v.city, v.comuna, v.attributes, v.use_cases, v.daily_price_clp, v.weekly_price_clp,
    v.min_days, v.verified,
    (select ph.storage_path from public.vehicle_photos ph
      where ph.vehicle_id = v.id order by ph.position, ph.created_at limit 1)
  from public.vehicles v
  join public.profiles p on p.id = v.owner_id
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
  order by v.verified desc, v.created_at desc
  limit least(greatest(p_limit, 1), 50)
  offset greatest(p_offset, 0)
$$;

-- -----------------------------------------------------------------------------
-- Casillas de aceptación por reserva (cláusulas 6 y 24)
-- -----------------------------------------------------------------------------

create table if not exists public.booking_consents (
  id                    bigint generated always as identity primary key,
  booking_id            uuid not null references public.bookings (id) on delete cascade,
  user_id               uuid not null references public.profiles (id) on delete cascade,
  terms_version         text not null,
  terms_accepted        boolean not null,          -- Casilla A
  data_sharing_accepted boolean not null,          -- Casilla C (separada)
  created_at            timestamptz not null default now()
);

create index if not exists booking_consents_booking_idx on public.booking_consents (booking_id);

alter table public.booking_consents enable row level security;

create policy "booking_consents: el usuario ve las suyas"
  on public.booking_consents for select to authenticated using (user_id = auth.uid());

revoke all on public.booking_consents from anon;
revoke insert, update, delete on public.booking_consents from authenticated;
grant select on public.booking_consents to authenticated;

-- Nueva firma de request_booking: exige la casilla A y registra la C.
drop function if exists public.request_booking(uuid, date, date, public.booking_purpose, text);

create or replace function public.request_booking(
  p_vehicle_id uuid,
  p_start date,
  p_end date,
  p_purpose public.booking_purpose default null,
  p_message text default null,
  p_terms_version text default null,
  p_accept_terms boolean default false,
  p_accept_data_sharing boolean default false
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v   public.vehicles%rowtype;
  p   record;
  new_id uuid;
  current_terms text := (select value #>> '{}' from public.platform_settings where key = 'terms_version');
begin
  if uid is null then
    raise exception 'Tienes que iniciar sesión' using errcode = '42501';
  end if;
  if not coalesce(p_accept_terms, false) then
    raise exception 'Para reservar debes aceptar los Términos y Condiciones' using errcode = '22023';
  end if;
  if p_terms_version is distinct from current_terms then
    raise exception 'Los Términos cambiaron. Actualiza la app para ver la versión vigente.' using errcode = 'P0001';
  end if;

  select * into v from public.vehicles where id = p_vehicle_id for share;
  if not found then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;
  if v.owner_id = uid then
    raise exception 'No puedes arrendar tu propio vehículo' using errcode = 'P0001';
  end if;
  if public.is_blocked_between(uid, v.owner_id) then
    raise exception 'No puedes solicitar este vehículo' using errcode = 'P0001';
  end if;
  if coalesce((select (value #>> '{}')::boolean from public.platform_settings where key = 'require_vehicle_verification'), false)
     and not (v.verified and v.verified_until >= public.today_cl()) then
    raise exception 'Este vehículo no está disponible por ahora' using errcode = 'P0001';
  end if;

  perform public.assert_can_rent();
  perform public.assert_bookable(v, p_start, p_end);

  if exists (
    select 1 from public.bookings b
    where b.vehicle_id = p_vehicle_id and b.renter_id = uid and b.status = 'solicitada'
      and daterange(b.start_date, b.end_date, '[)') && daterange(p_start, p_end, '[)')
  ) then
    raise exception 'Ya tienes una solicitud para este vehículo en esas fechas' using errcode = 'P0001';
  end if;

  select * into p from public.compute_booking_price(p_vehicle_id, p_start, p_end);

  insert into public.bookings (
    vehicle_id, renter_id, owner_id, status, purpose, start_date, end_date, days,
    rental_clp, renter_fee_clp, owner_commission_clp, total_clp, owner_payout_clp, deposit_clp,
    renter_message, expires_at
  ) values (
    v.id, uid, v.owner_id, 'solicitada', p_purpose, p_start, p_end, p.days,
    p.rental_clp, p.renter_fee_clp, p.owner_commission_clp, p.total_clp, p.owner_payout_clp, p.deposit_clp,
    nullif(btrim(left(p_message, 1000)), ''),
    now() + make_interval(hours => coalesce(public.setting_numeric('request_expiry_hours'), 24)::int)
  )
  returning id into new_id;

  insert into public.booking_consents (booking_id, user_id, terms_version, terms_accepted, data_sharing_accepted)
  values (new_id, uid, current_terms, true, coalesce(p_accept_data_sharing, false));

  return new_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Actas de entrega y devolución (cláusula 11)
-- -----------------------------------------------------------------------------

create table if not exists public.booking_handovers (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.bookings (id) on delete cascade,
  kind        text not null check (kind in ('entrega', 'devolucion')),
  author_id   uuid not null references public.profiles (id) on delete cascade,
  odometer_km int check (odometer_km is null or odometer_km between 0 and 3000000),
  fuel_level  int check (fuel_level is null or fuel_level between 0 and 100),
  notes       text check (char_length(notes) <= 2000),
  photo_paths text[] not null default '{}',
  created_at  timestamptz not null default now(),
  constraint booking_handovers_photos_limit check (cardinality(photo_paths) <= 20)
);

create index if not exists booking_handovers_booking_idx on public.booking_handovers (booking_id, created_at);

alter table public.booking_handovers enable row level security;

create policy "booking_handovers: participantes leen"
  on public.booking_handovers for select to authenticated
  using (exists (
    select 1 from public.bookings b
    where b.id = booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
  ));

revoke all on public.booking_handovers from anon;
revoke insert, update, delete on public.booking_handovers from authenticated;
grant select on public.booking_handovers to authenticated;

-- Cualquiera de las partes registra un acta (o su observación). Las fotos van en
-- el bucket privado `handovers`, carpeta <booking_id>/.
create or replace function public.submit_handover(
  p_booking_id uuid, p_kind text, p_odometer_km int, p_fuel_level int, p_notes text, p_photo_paths text[]
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  b public.bookings%rowtype;
  new_id uuid;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or uid is null or (b.owner_id <> uid and b.renter_id <> uid) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  if p_kind = 'entrega' and b.status not in ('confirmada', 'en_curso') then
    raise exception 'El acta de entrega se completa cuando la reserva está confirmada' using errcode = 'P0001';
  end if;
  if p_kind = 'devolucion' and b.status not in ('en_curso', 'devuelta') then
    raise exception 'El acta de devolución se completa cuando el vehículo está en arriendo' using errcode = 'P0001';
  end if;
  if exists (select 1 from unnest(coalesce(p_photo_paths, '{}')) ph where split_part(ph, '/', 1) <> b.id::text) then
    raise exception 'Fotos no válidas' using errcode = '22023';
  end if;
  insert into public.booking_handovers (booking_id, kind, author_id, odometer_km, fuel_level, notes, photo_paths)
  values (b.id, p_kind, uid, p_odometer_km, p_fuel_level, nullif(btrim(p_notes), ''), coalesce(p_photo_paths, '{}'))
  returning id into new_id;
  return new_id;
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('handovers', 'handovers', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function public.is_booking_participant(p_booking text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.bookings b
    where b.id::text = p_booking and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
  )
$$;

create policy "handovers: participantes leen"
  on storage.objects for select to authenticated
  using (bucket_id = 'handovers' and (public.is_booking_participant((storage.foldername(name))[1]) or public.is_admin()));

create policy "handovers: participantes suben"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'handovers' and public.is_booking_participant((storage.foldername(name))[1]));

-- Documentos de vehículos: el admin también debe poder verlos (ya cubierto por
-- "documents: administradores leen" de 0003).

-- Sin acta no hay entrega ni devolución (reemplaza transition_booking de 0002).
create or replace function public.transition_booking(
  p_booking_id uuid,
  p_to public.booking_status,
  p_note text default null
)
returns public.bookings
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  b    public.bookings%rowtype;
  role text;
  ok   boolean := false;
begin
  if uid is null then
    raise exception 'Tienes que iniciar sesión' using errcode = '42501';
  end if;

  select * into b from public.bookings where id = p_booking_id for update;
  if not found or (b.owner_id <> uid and b.renter_id <> uid) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;

  role := case when b.owner_id = uid then 'owner' else 'renter' end;

  ok := case role
    when 'owner' then (b.status, p_to) in (
      ('solicitada', 'aceptada'), ('solicitada', 'rechazada'),
      ('aceptada',   'cancelada'),
      ('confirmada', 'en_curso'),
      ('en_curso',   'devuelta'),
      ('devuelta',   'finalizada'),
      ('en_curso',   'disputada'), ('devuelta', 'disputada')
    )
    when 'renter' then (b.status, p_to) in (
      ('solicitada', 'cancelada'),
      ('aceptada',   'cancelada'),
      ('en_curso',   'disputada'), ('devuelta', 'disputada')
    )
  end;

  if not ok then
    raise exception 'No puedes hacer ese cambio en esta reserva' using errcode = '42501';
  end if;

  if p_to = 'aceptada' then
    if b.expires_at is not null and b.expires_at < now() then
      raise exception 'Esta solicitud ya venció' using errcode = 'P0001';
    end if;
    if not public.vehicle_is_available(b.vehicle_id, b.start_date, b.end_date, b.id) then
      raise exception 'Ya tienes otra reserva que se cruza con estas fechas' using errcode = 'P0001';
    end if;
  end if;

  if p_to = 'en_curso' then
    if public.today_cl() < b.start_date then
      raise exception 'La entrega se puede marcar desde el %', to_char(b.start_date, 'DD-MM-YYYY') using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.booking_handovers where booking_id = b.id and kind = 'entrega') then
      raise exception 'Primero completa el acta de entrega (kilometraje, combustible y fotos)' using errcode = 'P0001';
    end if;
  end if;

  if p_to = 'devuelta' and not exists (select 1 from public.booking_handovers where booking_id = b.id and kind = 'devolucion') then
    raise exception 'Primero completa el acta de devolución (kilometraje, combustible y fotos)' using errcode = 'P0001';
  end if;

  perform set_config('rue.transition_note', coalesce(left(p_note, 500), ''), true);

  update public.bookings
     set status = p_to,
         cancelled_by = case when p_to = 'cancelada' then uid else cancelled_by end,
         expires_at = case
           when p_to = 'aceptada'
             then now() + make_interval(hours => coalesce(public.setting_numeric('payment_expiry_hours'), 24)::int)
           else null
         end
   where id = b.id
   returning * into b;

  if p_to = 'aceptada' then
    perform set_config('rue.transition_note', 'Rechazada automáticamente: el vehículo se reservó para esas fechas', true);
    update public.bookings o
       set status = 'rechazada', expires_at = null
     where o.vehicle_id = b.vehicle_id
       and o.id <> b.id
       and o.status = 'solicitada'
       and daterange(o.start_date, o.end_date, '[)') && daterange(b.start_date, b.end_date, '[)');
  end if;

  perform set_config('rue.transition_note', '', true);
  return b;
exception
  when exclusion_violation then
    raise exception 'Ya tienes otra reserva que se cruza con estas fechas' using errcode = 'P0001';
end;
$$;

-- -----------------------------------------------------------------------------
-- Bitácora de comunicación de datos (cláusula 18). Solo administradores.
-- -----------------------------------------------------------------------------

create table if not exists public.data_disclosures (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references public.bookings (id) on delete restrict,
  subject_user_id  uuid not null references public.profiles (id) on delete restrict,
  recipient_name   text not null,
  recipient_role   text not null check (recipient_role in ('arrendador', 'abogado', 'arrendatario', 'autoridad', 'aseguradora')),
  data_shared      text not null,
  reason           text not null,
  subject_notified boolean not null default false,
  created_by       uuid references auth.users (id),
  created_at       timestamptz not null default now()
);

alter table public.data_disclosures enable row level security;

create policy "data_disclosures: administradores"
  on public.data_disclosures for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy "data_disclosures: el titular ve las suyas"
  on public.data_disclosures for select to authenticated using (subject_user_id = auth.uid());

revoke all on public.data_disclosures from anon;
grant select, insert on public.data_disclosures to authenticated;

-- -----------------------------------------------------------------------------
-- Cron diario de vencimiento de verificaciones de vehículos
-- -----------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('rue-expire-vehicle-verifications', '15 7 * * *', 'select public.expire_vehicle_verifications()');
  else
    raise notice 'pg_cron no está disponible: expire_vehicle_verifications() no se programó.';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------

revoke execute on function public.submit_vehicle_verification(uuid, text, text, date) from public, anon;
revoke execute on function public.review_vehicle_verification(uuid, boolean, text) from public, anon;
revoke execute on function public.enforce_vehicle_publication() from public, anon, authenticated;
revoke execute on function public.expire_vehicle_verifications() from public, anon, authenticated;
revoke execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean) from public, anon;
revoke execute on function public.submit_handover(uuid, text, int, int, text, text[]) from public, anon;
revoke execute on function public.is_booking_participant(text) from public, anon;
revoke execute on function public.transition_booking(uuid, public.booking_status, text) from public, anon;
revoke execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) from public, anon;

grant execute on function public.submit_vehicle_verification(uuid, text, text, date) to authenticated;
grant execute on function public.review_vehicle_verification(uuid, boolean, text) to authenticated, service_role;
grant execute on function public.expire_vehicle_verifications() to service_role;
grant execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean) to authenticated;
grant execute on function public.submit_handover(uuid, text, int, int, text, text[]) to authenticated;
grant execute on function public.is_booking_participant(text) to authenticated;
grant execute on function public.transition_booking(uuid, public.booking_status, text) to authenticated;
grant execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) to authenticated;
