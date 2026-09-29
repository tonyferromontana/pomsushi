-- =============================================================================
-- RUÉ · 0001 · Esquema base del marketplace de activos de movilidad
--
-- Crea: tipos, perfiles (público + privado), vehículos multimodales, fotos,
-- bloqueos de disponibilidad, reservas, eventos de reserva, mensajes, pagos,
-- configuración de la plataforma, buckets de Storage y todas las policies RLS.
--
-- Reglas que este archivo hace cumplir:
--   * Toda tabla tiene Row Level Security.
--   * RUT, teléfono, dirección y documentos viven en tablas/buckets privados.
--   * El cliente NO puede insertar ni actualizar reservas ni pagos directamente:
--     solo mediante las funciones de 0002 (security definer).
--
-- Reversión conceptual: drop de las tablas en orden inverso + drop de los tipos.
-- =============================================================================

create extension if not exists btree_gist;

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------

do $$ begin
  create type public.vehicle_type as enum (
    'car', 'motorcycle', 'suv', 'pickup', 'van', 'cargo_van',
    'truck', 'minibus', 'trailer', 'special'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.listing_status as enum ('borrador', 'publicado', 'pausado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.booking_status as enum (
    'solicitada', 'aceptada', 'confirmada', 'en_curso', 'devuelta', 'finalizada',
    'rechazada', 'cancelada', 'vencida', 'disputada'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.booking_purpose as enum (
    'viaje', 'ciudad', 'trabajo', 'aplicaciones', 'reparto', 'carga', 'otro'
  );
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- Utilidad: updated_at automático
-- -----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Configuración de la plataforma (comisiones, plazos). Solo servidor.
-- Los valores iniciales son 0 / neutros: el dueño del negocio define los reales.
-- -----------------------------------------------------------------------------

create table if not exists public.platform_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now()
);

alter table public.platform_settings enable row level security;
-- Sin policies: ni anon ni authenticated pueden leerla ni escribirla.
-- Las funciones security definer de 0002 la leen.

insert into public.platform_settings (key, value, description) values
  ('owner_commission_pct',     '0',  'Porcentaje que RUÉ retiene al propietario (0-100). POR DEFINIR por el negocio.'),
  ('renter_service_fee_pct',   '0',  'Cargo de servicio al arrendatario en % del subtotal (0-100). POR DEFINIR por el negocio.'),
  ('request_expiry_hours',     '24', 'Horas que tiene el propietario para responder una solicitud.'),
  ('payment_expiry_hours',     '24', 'Horas que tiene el arrendatario para pagar una reserva aceptada.'),
  ('max_booking_days',         '90', 'Máximo de días por reserva.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- Perfiles
-- profiles:          datos públicos (nombre visible, foto, ciudad, verificaciones)
-- profile_private:   datos sensibles, solo el propio usuario
-- -----------------------------------------------------------------------------

create table if not exists public.profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  display_name       text not null default '' check (char_length(display_name) <= 60),
  avatar_url         text,
  bio                text check (char_length(bio) <= 500),
  city               text check (char_length(city) <= 80),
  -- Verificaciones: solo las cambia el servidor.
  identity_verified  boolean not null default false,
  license_verified   boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;

create policy "profiles: lectura para usuarios autenticados"
  on public.profiles for select to authenticated using (true);

create policy "profiles: cada uno edita el suyo"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Solo estas columnas son editables por el usuario (no las verificaciones).
revoke insert, update, delete on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, avatar_url, bio, city) on public.profiles to authenticated;

create table if not exists public.profile_private (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  rut         text check (rut is null or rut ~ '^[0-9]{7,8}-[0-9Kk]$'),
  phone       text check (phone is null or phone ~ '^\+?[0-9 ]{8,15}$'),
  birth_date  date,
  address     text check (char_length(address) <= 200),
  updated_at  timestamptz not null default now()
);

create trigger profile_private_updated_at before update on public.profile_private
  for each row execute function public.set_updated_at();

alter table public.profile_private enable row level security;

create policy "profile_private: solo el dueño lee"
  on public.profile_private for select to authenticated using (user_id = auth.uid());

create policy "profile_private: solo el dueño edita"
  on public.profile_private for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.profile_private from anon;
revoke insert, delete on public.profile_private from authenticated;
grant select on public.profile_private to authenticated;
grant update (rut, phone, birth_date, address) on public.profile_private to authenticated;

-- Crear perfil al registrarse.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(left(new.raw_user_meta_data ->> 'display_name', 60), ''))
  on conflict (id) do nothing;

  insert into public.profile_private (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- Vehículos (activos). Un solo modelo para todos los tipos.
-- Los atributos que cambian según el tipo (transmisión, cilindrada, tonelaje…)
-- van en `attributes` (jsonb) y se validan con validate_vehicle_attributes().
-- -----------------------------------------------------------------------------

create or replace function public.validate_vehicle_attributes(t public.vehicle_type, a jsonb)
returns boolean
language sql
immutable
as $$
  select
    jsonb_typeof(a) = 'object'
    -- Solo se permiten claves conocidas
    and not exists (
      select 1 from jsonb_object_keys(a) k
      where k not in (
        'transmission', 'fuel', 'seats', 'doors', 'traction',
        'engine_cc', 'cargo_kg', 'cargo_m3', 'body', 'license_class'
      )
    )
    and (a -> 'transmission' is null or a ->> 'transmission' in ('manual', 'automatica'))
    and (a -> 'fuel' is null or a ->> 'fuel' in ('bencina', 'diesel', 'hibrido', 'electrico', 'gas'))
    and (a -> 'traction' is null or a ->> 'traction' in ('4x2', '4x4', 'awd'))
    and (a -> 'seats' is null or (jsonb_typeof(a -> 'seats') = 'number' and (a ->> 'seats')::numeric between 1 and 60))
    and (a -> 'doors' is null or (jsonb_typeof(a -> 'doors') = 'number' and (a ->> 'doors')::numeric between 0 and 6))
    and (a -> 'engine_cc' is null or (jsonb_typeof(a -> 'engine_cc') = 'number' and (a ->> 'engine_cc')::numeric between 0 and 20000))
    and (a -> 'cargo_kg' is null or (jsonb_typeof(a -> 'cargo_kg') = 'number' and (a ->> 'cargo_kg')::numeric between 0 and 60000))
    and (a -> 'cargo_m3' is null or (jsonb_typeof(a -> 'cargo_m3') = 'number' and (a ->> 'cargo_m3')::numeric between 0 and 200))
    and (a -> 'body' is null or jsonb_typeof(a -> 'body') = 'string')
    and (a -> 'license_class' is null or a ->> 'license_class' in ('A1', 'A2', 'A3', 'A4', 'A5', 'B', 'C', 'D'))
    -- Una moto no tiene carga en m3 ni puertas
    and not (t = 'motorcycle' and (a ? 'cargo_m3' or a ? 'doors'))
$$;

create table if not exists public.vehicles (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.profiles (id) on delete cascade,
  vehicle_type     public.vehicle_type not null,
  status           public.listing_status not null default 'borrador',
  title            text not null check (char_length(title) between 3 and 80),
  brand            text not null check (char_length(brand) between 1 and 40),
  model            text not null check (char_length(model) between 1 and 40),
  year             int  not null check (year between 1950 and 2100),
  description      text check (char_length(description) <= 2000),
  city             text not null check (char_length(city) between 2 and 80),
  comuna           text check (char_length(comuna) <= 80),
  attributes       jsonb not null default '{}'::jsonb,
  use_cases        public.booking_purpose[] not null default '{}',
  -- Precio que pide el propietario (CLP por día). El total lo calcula el servidor.
  daily_price_clp  int not null check (daily_price_clp between 1000 and 10000000),
  -- Precio semanal opcional (por 7 días). Si existe, el servidor lo aplica.
  weekly_price_clp int check (weekly_price_clp is null or weekly_price_clp between 1000 and 70000000),
  deposit_clp      int not null default 0 check (deposit_clp between 0 and 50000000),
  min_days         int not null default 1 check (min_days between 1 and 90),
  -- Verificación del vehículo: solo servidor.
  verified         boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint vehicles_attributes_valid check (public.validate_vehicle_attributes(vehicle_type, attributes))
);

create index if not exists vehicles_search_idx on public.vehicles (status, vehicle_type, city);
create index if not exists vehicles_owner_idx on public.vehicles (owner_id);

create trigger vehicles_updated_at before update on public.vehicles
  for each row execute function public.set_updated_at();

alter table public.vehicles enable row level security;

create policy "vehicles: publicados son visibles para todos"
  on public.vehicles for select to anon, authenticated
  using (status = 'publicado' or owner_id = auth.uid());

create policy "vehicles: el propietario crea"
  on public.vehicles for insert to authenticated
  with check (owner_id = auth.uid());

create policy "vehicles: el propietario edita"
  on public.vehicles for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy "vehicles: el propietario borra"
  on public.vehicles for delete to authenticated
  using (owner_id = auth.uid());

revoke insert, update, delete on public.vehicles from anon, authenticated;
grant select on public.vehicles to anon, authenticated;
grant insert (id, owner_id, vehicle_type, status, title, brand, model, year, description, city, comuna,
              attributes, use_cases, daily_price_clp, weekly_price_clp, deposit_clp, min_days)
  on public.vehicles to authenticated;
grant update (vehicle_type, status, title, brand, model, year, description, city, comuna,
              attributes, use_cases, daily_price_clp, weekly_price_clp, deposit_clp, min_days)
  on public.vehicles to authenticated;
grant delete on public.vehicles to authenticated;

-- Fotos (el archivo vive en Storage, bucket vehicle-photos)
create table if not exists public.vehicle_photos (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references public.vehicles (id) on delete cascade,
  storage_path  text not null,
  position      int  not null default 0 check (position between 0 and 30),
  created_at    timestamptz not null default now()
);

create index if not exists vehicle_photos_vehicle_idx on public.vehicle_photos (vehicle_id, position);

alter table public.vehicle_photos enable row level security;

create policy "vehicle_photos: visibles si el vehículo es visible"
  on public.vehicle_photos for select to anon, authenticated
  using (exists (
    select 1 from public.vehicles v
    where v.id = vehicle_id and (v.status = 'publicado' or v.owner_id = auth.uid())
  ));

create policy "vehicle_photos: el propietario administra"
  on public.vehicle_photos for all to authenticated
  using (exists (select 1 from public.vehicles v where v.id = vehicle_id and v.owner_id = auth.uid()))
  with check (
    exists (select 1 from public.vehicles v where v.id = vehicle_id and v.owner_id = auth.uid())
    and split_part(storage_path, '/', 1) = auth.uid()::text
  );

grant select on public.vehicle_photos to anon, authenticated;
grant insert, update, delete on public.vehicle_photos to authenticated;

-- Bloqueos de disponibilidad definidos por el propietario ([start_date, end_date) )
create table if not exists public.vehicle_blocks (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references public.vehicles (id) on delete cascade,
  start_date  date not null,
  end_date    date not null,
  reason      text check (char_length(reason) <= 120),
  created_at  timestamptz not null default now(),
  constraint vehicle_blocks_range check (end_date > start_date)
);

create index if not exists vehicle_blocks_vehicle_idx on public.vehicle_blocks (vehicle_id, start_date);

alter table public.vehicle_blocks enable row level security;

create policy "vehicle_blocks: visibles si el vehículo es visible"
  on public.vehicle_blocks for select to anon, authenticated
  using (exists (
    select 1 from public.vehicles v
    where v.id = vehicle_id and (v.status = 'publicado' or v.owner_id = auth.uid())
  ));

create policy "vehicle_blocks: el propietario administra"
  on public.vehicle_blocks for all to authenticated
  using (exists (select 1 from public.vehicles v where v.id = vehicle_id and v.owner_id = auth.uid()))
  with check (exists (select 1 from public.vehicles v where v.id = vehicle_id and v.owner_id = auth.uid()));

grant select on public.vehicle_blocks to anon, authenticated;
grant insert, update, delete on public.vehicle_blocks to authenticated;

-- -----------------------------------------------------------------------------
-- Reservas
-- Fechas: [start_date, end_date) → días = end_date - start_date.
-- Todos los montos se calculan en servidor (0002) y quedan congelados aquí.
-- -----------------------------------------------------------------------------

create table if not exists public.bookings (
  id                     uuid primary key default gen_random_uuid(),
  vehicle_id             uuid not null references public.vehicles (id) on delete restrict,
  renter_id              uuid not null references public.profiles (id) on delete restrict,
  owner_id               uuid not null references public.profiles (id) on delete restrict,
  status                 public.booking_status not null default 'solicitada',
  purpose                public.booking_purpose,
  start_date             date not null,
  end_date               date not null,
  days                   int  not null check (days > 0),
  -- Montos en CLP (enteros), calculados por el servidor
  rental_clp             int  not null check (rental_clp >= 0),
  renter_fee_clp         int  not null check (renter_fee_clp >= 0),
  owner_commission_clp   int  not null check (owner_commission_clp >= 0),
  total_clp              int  not null check (total_clp >= 0),
  owner_payout_clp       int  not null check (owner_payout_clp >= 0),
  deposit_clp            int  not null check (deposit_clp >= 0),
  renter_message         text check (char_length(renter_message) <= 1000),
  expires_at             timestamptz,
  accepted_at            timestamptz,
  confirmed_at           timestamptz,
  started_at             timestamptz,
  returned_at            timestamptz,
  finished_at            timestamptz,
  cancelled_at           timestamptz,
  cancelled_by           uuid references public.profiles (id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint bookings_range check (end_date > start_date),
  constraint bookings_not_self check (renter_id <> owner_id),
  -- Nunca dos reservas activas del mismo vehículo que se crucen.
  constraint bookings_no_overlap exclude using gist (
    vehicle_id with =,
    daterange(start_date, end_date, '[)') with &&
  ) where (status in ('aceptada', 'confirmada', 'en_curso', 'devuelta', 'disputada'))
);

create index if not exists bookings_renter_idx on public.bookings (renter_id, created_at desc);
create index if not exists bookings_owner_idx  on public.bookings (owner_id, created_at desc);
create index if not exists bookings_vehicle_idx on public.bookings (vehicle_id, start_date);

create trigger bookings_updated_at before update on public.bookings
  for each row execute function public.set_updated_at();

alter table public.bookings enable row level security;

create policy "bookings: solo participantes leen"
  on public.bookings for select to authenticated
  using (renter_id = auth.uid() or owner_id = auth.uid());

-- Nada de insert/update/delete directo desde la app.
revoke all on public.bookings from anon;
revoke insert, update, delete on public.bookings from authenticated;
grant select on public.bookings to authenticated;

-- Historial de cambios de estado (auditoría)
create table if not exists public.booking_events (
  id           bigint generated always as identity primary key,
  booking_id   uuid not null references public.bookings (id) on delete cascade,
  from_status  public.booking_status,
  to_status    public.booking_status not null,
  actor_id     uuid,              -- null = sistema (webhook, cron)
  note         text,
  created_at   timestamptz not null default now()
);

create index if not exists booking_events_booking_idx on public.booking_events (booking_id, created_at);

alter table public.booking_events enable row level security;

create policy "booking_events: participantes leen"
  on public.booking_events for select to authenticated
  using (exists (
    select 1 from public.bookings b
    where b.id = booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
  ));

revoke all on public.booking_events from anon;
revoke insert, update, delete on public.booking_events from authenticated;
grant select on public.booking_events to authenticated;

-- -----------------------------------------------------------------------------
-- Mensajes (chat por reserva). Solo participantes. Hora del servidor.
-- -----------------------------------------------------------------------------

create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.bookings (id) on delete cascade,
  sender_id   uuid not null references public.profiles (id) on delete cascade,
  body        text not null check (char_length(btrim(body)) between 1 and 2000),
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists messages_booking_idx on public.messages (booking_id, created_at);

alter table public.messages enable row level security;

create policy "messages: participantes leen"
  on public.messages for select to authenticated
  using (exists (
    select 1 from public.bookings b
    where b.id = booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
  ));

create policy "messages: participantes escriben como sí mismos"
  on public.messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.bookings b
      where b.id = booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
    )
  );

revoke all on public.messages from anon;
revoke insert, update, delete on public.messages from authenticated;
grant select on public.messages to authenticated;
grant insert (booking_id, sender_id, body) on public.messages to authenticated;

-- -----------------------------------------------------------------------------
-- Pagos (Mercado Pago). Solo el servidor escribe. Nunca datos de tarjeta.
-- -----------------------------------------------------------------------------

create table if not exists public.payments (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references public.bookings (id) on delete restrict,
  provider         text not null default 'mercadopago',
  environment      text not null check (environment in ('test', 'prod')),
  preference_id    text,
  provider_payment_id text,
  status           text not null default 'pending',  -- estado tal como lo informa el proveedor
  amount_clp       int  not null check (amount_clp >= 0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint payments_provider_payment_unique unique (provider, provider_payment_id)
);

create index if not exists payments_booking_idx on public.payments (booking_id);

create trigger payments_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

alter table public.payments enable row level security;

create policy "payments: participantes leen"
  on public.payments for select to authenticated
  using (exists (
    select 1 from public.bookings b
    where b.id = booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
  ));

revoke all on public.payments from anon;
revoke insert, update, delete on public.payments from authenticated;
grant select on public.payments to authenticated;

-- Eventos crudos de webhook para idempotencia y diagnóstico. Solo servidor.
create table if not exists public.payment_events (
  id            bigint generated always as identity primary key,
  provider      text not null,
  event_key     text not null,   -- id único del evento según el proveedor
  payload       jsonb not null,
  processed_at  timestamptz,
  error         text,
  created_at    timestamptz not null default now(),
  constraint payment_events_unique unique (provider, event_key)
);

alter table public.payment_events enable row level security;
revoke all on public.payment_events from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Storage
--   vehicle-photos: lectura pública; cada usuario escribe solo en <su uid>/...
--   documents:      privado; cada usuario solo accede a <su uid>/...
-- -----------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('vehicle-photos', 'vehicle-photos', true,  5242880,  array['image/jpeg', 'image/png', 'image/webp']),
  ('documents',      'documents',      false, 10485760, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

create policy "vehicle-photos: lectura pública"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'vehicle-photos');

create policy "vehicle-photos: subir a su carpeta"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicle-photos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "vehicle-photos: borrar de su carpeta"
  on storage.objects for delete to authenticated
  using (bucket_id = 'vehicle-photos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "documents: el dueño lee"
  on storage.objects for select to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "documents: el dueño sube"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "documents: el dueño borra"
  on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = auth.uid()::text);

-- -----------------------------------------------------------------------------
-- Realtime: chat y cambios de reserva (RLS se respeta en Realtime)
-- -----------------------------------------------------------------------------

do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; when undefined_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.bookings;
exception when duplicate_object then null; when undefined_object then null; end $$;
