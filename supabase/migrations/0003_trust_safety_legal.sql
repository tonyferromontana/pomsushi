-- =============================================================================
-- RUÉ · 0003 · Confianza, seguridad y requisitos legales / de tiendas
--
--   * legal_acceptances:     registro de aceptación de Términos y Privacidad (versión + fecha).
--   * verification_requests: el usuario sube licencia / cédula (bucket privado `documents`);
--                            un administrador aprueba o rechaza. Solo el servidor marca verificado.
--   * reviews:               reseñas después de una reserva finalizada (una por persona y reserva).
--   * reports / user_blocks: reportar y bloquear (exigido por App Store para contenido de usuarios).
--   * notifications:         bandeja de avisos generada por triggers del servidor.
--   * push_tokens:           tokens de notificaciones push de cada dispositivo.
--   * payout_accounts:       datos bancarios del propietario (privados).
--   * payouts:               pagos de RUÉ a propietarios (solo servidor escribe).
--   * admins:                quién puede revisar verificaciones y reportes.
--   * delete_my_account():   anonimiza la cuenta (exigido por App Store y Google Play).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Administradores (se agregan a mano desde el SQL Editor)
-- -----------------------------------------------------------------------------

create table if not exists public.admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- -----------------------------------------------------------------------------
-- Aceptación de documentos legales
-- -----------------------------------------------------------------------------

insert into public.platform_settings (key, value, description) values
  ('terms_version',             '"2026-10-01"', 'Versión vigente de Términos y Condiciones y Política de Privacidad.'),
  ('require_verified_license',  'false',        'Si es true, solo usuarios con licencia verificada pueden solicitar reservas.')
on conflict (key) do nothing;

create table if not exists public.legal_acceptances (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  version     text not null,
  accepted_at timestamptz not null default now(),
  constraint legal_acceptances_unique unique (user_id, version)
);
alter table public.legal_acceptances enable row level security;

create policy "legal_acceptances: el usuario ve las suyas"
  on public.legal_acceptances for select to authenticated using (user_id = auth.uid());

revoke all on public.legal_acceptances from anon;
revoke insert, update, delete on public.legal_acceptances from authenticated;
grant select on public.legal_acceptances to authenticated;

create or replace function public.accept_terms(p_version text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Tienes que iniciar sesión' using errcode = '42501';
  end if;
  if p_version is distinct from (select value #>> '{}' from public.platform_settings where key = 'terms_version') then
    raise exception 'Hay una versión más nueva de los términos. Actualiza la app.' using errcode = 'P0001';
  end if;
  insert into public.legal_acceptances (user_id, version) values (auth.uid(), p_version)
  on conflict (user_id, version) do nothing;
end;
$$;

-- Al registrarse, si la app envió la versión aceptada, se registra automáticamente.
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

  if new.raw_user_meta_data ? 'terms_version' then
    insert into public.legal_acceptances (user_id, version)
    values (new.id, left(new.raw_user_meta_data ->> 'terms_version', 20))
    on conflict (user_id, version) do nothing;
  end if;

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Verificación de identidad y licencia
-- -----------------------------------------------------------------------------

do $$ begin
  create type public.verification_kind as enum ('identity', 'license');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.verification_status as enum ('pendiente', 'aprobada', 'rechazada');
exception when duplicate_object then null; end $$;

create table if not exists public.verification_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  kind          public.verification_kind not null,
  front_path    text not null,
  back_path     text,
  status        public.verification_status not null default 'pendiente',
  review_note   text check (char_length(review_note) <= 500),
  reviewed_by   uuid references auth.users (id),
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  constraint verification_paths_owned check (
    split_part(front_path, '/', 1) = user_id::text
    and (back_path is null or split_part(back_path, '/', 1) = user_id::text)
  )
);

create index if not exists verification_requests_user_idx on public.verification_requests (user_id, created_at desc);
create index if not exists verification_requests_pending_idx on public.verification_requests (status) where status = 'pendiente';

alter table public.verification_requests enable row level security;

create policy "verification_requests: el usuario ve las suyas"
  on public.verification_requests for select to authenticated using (user_id = auth.uid());

create policy "verification_requests: administradores ven todas"
  on public.verification_requests for select to authenticated using (public.is_admin());

-- Los administradores pueden ver los documentos para revisarlos.
create policy "documents: administradores leen"
  on storage.objects for select to authenticated
  using (bucket_id = 'documents' and public.is_admin());

revoke all on public.verification_requests from anon;
revoke insert, update, delete on public.verification_requests from authenticated;
grant select on public.verification_requests to authenticated;

create or replace function public.submit_verification(
  p_kind public.verification_kind, p_front_path text, p_back_path text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  new_id uuid;
begin
  if uid is null then
    raise exception 'Tienes que iniciar sesión' using errcode = '42501';
  end if;
  if exists (select 1 from public.verification_requests
             where user_id = uid and kind = p_kind and status = 'pendiente') then
    raise exception 'Ya tienes una verificación en revisión' using errcode = 'P0001';
  end if;
  insert into public.verification_requests (user_id, kind, front_path, back_path)
  values (uid, p_kind, p_front_path, p_back_path)
  returning id into new_id;
  return new_id;
end;
$$;

-- Solo administradores: aprobar o rechazar.
create or replace function public.review_verification(p_request_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.verification_requests%rowtype;
begin
  if not public.is_admin() and auth.role() is distinct from 'service_role' then
    raise exception 'Solo un administrador puede revisar verificaciones' using errcode = '42501';
  end if;
  select * into r from public.verification_requests where id = p_request_id for update;
  if not found then
    raise exception 'Solicitud no encontrada' using errcode = 'P0002';
  end if;
  update public.verification_requests
     set status = case when p_approve then 'aprobada'::public.verification_status else 'rechazada' end,
         review_note = p_note, reviewed_by = auth.uid(), reviewed_at = now()
   where id = r.id;
  if p_approve then
    if r.kind = 'identity' then
      update public.profiles set identity_verified = true where id = r.user_id;
    else
      update public.profiles set license_verified = true where id = r.user_id;
    end if;
  end if;
  insert into public.notifications (user_id, kind, title, body)
  values (r.user_id, 'verification',
          case when p_approve then 'Verificación aprobada' else 'Revisa tu verificación' end,
          case when p_approve
               then case when r.kind = 'identity' then 'Tu identidad quedó verificada.' else 'Tu licencia quedó verificada.' end
               else coalesce(p_note, 'No pudimos validar el documento. Vuelve a enviarlo.') end);
end;
$$;

-- Si la plataforma exige licencia verificada, se valida al solicitar una reserva.
create or replace function public.assert_can_rent()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce((select (value #>> '{}')::boolean from public.platform_settings where key = 'require_verified_license'), false)
     and not coalesce((select license_verified from public.profiles where id = auth.uid()), false) then
    raise exception 'Para arrendar necesitas verificar tu licencia de conducir en tu perfil' using errcode = 'P0001';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Bloqueos entre usuarios
-- -----------------------------------------------------------------------------

create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint user_blocks_not_self check (blocker_id <> blocked_id)
);

alter table public.user_blocks enable row level security;

create policy "user_blocks: el usuario administra los suyos"
  on public.user_blocks for all to authenticated
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

revoke all on public.user_blocks from anon;
grant select, insert, delete on public.user_blocks to authenticated;

create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  )
$$;

-- Versión para la app: solo responde por la relación entre quien pregunta y otra persona.
create or replace function public.is_blocked_with(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and public.is_blocked_between(auth.uid(), p_other)
$$;

-- Nadie puede escribir en un chat si hay un bloqueo entre las partes.
drop policy if exists "messages: participantes escriben como sí mismos" on public.messages;
create policy "messages: participantes escriben como sí mismos"
  on public.messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.bookings b
      where b.id = booking_id
        and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
        and not public.is_blocked_with(case when b.renter_id = auth.uid() then b.owner_id else b.renter_id end)
    )
  );

-- -----------------------------------------------------------------------------
-- Reportes
-- -----------------------------------------------------------------------------

create table if not exists public.reports (
  id                uuid primary key default gen_random_uuid(),
  reporter_id       uuid not null references public.profiles (id) on delete cascade,
  target_user_id    uuid references public.profiles (id) on delete cascade,
  target_vehicle_id uuid references public.vehicles (id) on delete cascade,
  booking_id        uuid references public.bookings (id) on delete cascade,
  reason            text not null check (reason in ('fraude', 'contenido_inapropiado', 'acoso', 'vehiculo_no_corresponde', 'seguridad', 'otro')),
  details           text check (char_length(details) <= 1000),
  status            text not null default 'abierto' check (status in ('abierto', 'en_revision', 'cerrado')),
  created_at        timestamptz not null default now(),
  constraint reports_has_target check (target_user_id is not null or target_vehicle_id is not null or booking_id is not null)
);

alter table public.reports enable row level security;

create policy "reports: el usuario crea como sí mismo"
  on public.reports for insert to authenticated with check (reporter_id = auth.uid());

create policy "reports: el usuario ve los suyos"
  on public.reports for select to authenticated using (reporter_id = auth.uid());

create policy "reports: administradores ven todos"
  on public.reports for select to authenticated using (public.is_admin());

revoke all on public.reports from anon;
revoke update, delete on public.reports from authenticated;
grant select on public.reports to authenticated;
grant insert (reporter_id, target_user_id, target_vehicle_id, booking_id, reason, details) on public.reports to authenticated;

-- -----------------------------------------------------------------------------
-- Reseñas
-- -----------------------------------------------------------------------------

create table if not exists public.reviews (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references public.bookings (id) on delete cascade,
  author_id      uuid not null references public.profiles (id) on delete cascade,
  target_user_id uuid not null references public.profiles (id) on delete cascade,
  vehicle_id     uuid references public.vehicles (id) on delete set null,
  rating         int not null check (rating between 1 and 5),
  comment        text check (char_length(comment) <= 800),
  created_at     timestamptz not null default now(),
  constraint reviews_one_per_author unique (booking_id, author_id)
);

create index if not exists reviews_target_idx on public.reviews (target_user_id, created_at desc);
create index if not exists reviews_vehicle_idx on public.reviews (vehicle_id, created_at desc);

alter table public.reviews enable row level security;

create policy "reviews: lectura para usuarios autenticados"
  on public.reviews for select to authenticated using (true);

revoke all on public.reviews from anon;
revoke insert, update, delete on public.reviews from authenticated;
grant select on public.reviews to authenticated;

create or replace function public.submit_review(p_booking_id uuid, p_rating int, p_comment text default null)
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
  if uid is null then
    raise exception 'Tienes que iniciar sesión' using errcode = '42501';
  end if;
  select * into b from public.bookings where id = p_booking_id;
  if not found or (b.owner_id <> uid and b.renter_id <> uid) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  if b.status <> 'finalizada' then
    raise exception 'Puedes dejar tu reseña cuando la reserva termine' using errcode = 'P0001';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'La nota debe ser de 1 a 5' using errcode = '22023';
  end if;
  insert into public.reviews (booking_id, author_id, target_user_id, vehicle_id, rating, comment)
  values (b.id, uid, case when uid = b.owner_id then b.renter_id else b.owner_id end,
          case when uid = b.renter_id then b.vehicle_id else null end,
          p_rating, nullif(btrim(left(p_comment, 800)), ''))
  returning id into new_id;
  return new_id;
exception
  when unique_violation then
    raise exception 'Ya dejaste tu reseña para esta reserva' using errcode = 'P0001';
end;
$$;

-- Reputación agregada (real, calculada desde las reservas y reseñas)
create or replace function public.user_reputation(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'rating_avg', (select round(avg(rating)::numeric, 1) from public.reviews where target_user_id = p_user_id),
    'rating_count', (select count(*) from public.reviews where target_user_id = p_user_id),
    'completed_bookings', (select count(*) from public.bookings
                           where (owner_id = p_user_id or renter_id = p_user_id) and status = 'finalizada')
  )
$$;

-- -----------------------------------------------------------------------------
-- Notificaciones (bandeja + push)
-- -----------------------------------------------------------------------------

create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  kind        text not null,
  title       text not null,
  body        text not null,
  booking_id  uuid references public.bookings (id) on delete cascade,
  read_at     timestamptz,
  pushed_at   timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
create index if not exists notifications_unpushed_idx on public.notifications (created_at) where pushed_at is null;

alter table public.notifications enable row level security;

create policy "notifications: el usuario ve las suyas"
  on public.notifications for select to authenticated using (user_id = auth.uid());

create policy "notifications: el usuario marca como leídas"
  on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.notifications from anon;
revoke insert, update, delete on public.notifications from authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; when undefined_object then null; end $$;

create table if not exists public.push_tokens (
  token       text primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  platform    text check (platform in ('ios', 'android', 'web')),
  updated_at  timestamptz not null default now()
);

alter table public.push_tokens enable row level security;

create policy "push_tokens: el usuario administra los suyos"
  on public.push_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.push_tokens from anon;
grant select, insert, update, delete on public.push_tokens to authenticated;

-- Genera avisos cuando cambia una reserva (servidor, nunca la app).
create or replace function public.notify_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  vtitle text := coalesce((select title from public.vehicles where id = new.vehicle_id), 'tu vehículo');
begin
  if tg_op = 'INSERT' then
    insert into public.notifications (user_id, kind, title, body, booking_id)
    values (new.owner_id, 'booking_requested', 'Nueva solicitud',
            'Alguien quiere arrendar ' || vtitle || '. Respóndele pronto.', new.id);
    return null;
  end if;

  if new.status is not distinct from old.status then
    return null;
  end if;

  case new.status
    when 'aceptada' then
      insert into public.notifications (user_id, kind, title, body, booking_id)
      values (new.renter_id, 'booking_accepted', '¡Te aceptaron!', 'Paga para confirmar ' || vtitle || '.', new.id);
    when 'rechazada' then
      insert into public.notifications (user_id, kind, title, body, booking_id)
      values (new.renter_id, 'booking_rejected', 'Solicitud no aceptada',
              vtitle || ' no está disponible. Prueba con otro vehículo.', new.id);
    when 'confirmada' then
      insert into public.notifications (user_id, kind, title, body, booking_id) values
        (new.renter_id, 'payment_confirmed', 'Reserva confirmada', 'Recibimos tu pago de ' || vtitle || '.', new.id),
        (new.owner_id,  'payment_confirmed', 'Reserva pagada', 'La reserva de ' || vtitle || ' está pagada y confirmada.', new.id);
    when 'en_curso' then
      insert into public.notifications (user_id, kind, title, body, booking_id)
      values (new.renter_id, 'booking_started', 'Arriendo en curso', 'Disfruta ' || vtitle || '. Cuídalo como propio.', new.id);
    when 'devuelta' then
      insert into public.notifications (user_id, kind, title, body, booking_id)
      values (new.renter_id, 'booking_returned', 'Devolución registrada', 'El propietario recibió ' || vtitle || '.', new.id);
    when 'finalizada' then
      insert into public.notifications (user_id, kind, title, body, booking_id) values
        (new.renter_id, 'booking_finished', 'Reserva finalizada', 'Cuéntanos cómo te fue: deja tu reseña.', new.id),
        (new.owner_id,  'booking_finished', 'Reserva finalizada', 'Cuéntanos cómo te fue: deja tu reseña.', new.id);
    when 'cancelada' then
      insert into public.notifications (user_id, kind, title, body, booking_id)
      values (case when new.cancelled_by = new.owner_id then new.renter_id else new.owner_id end,
              'booking_cancelled', 'Reserva cancelada', 'Se canceló la reserva de ' || vtitle || '.', new.id);
    when 'vencida' then
      insert into public.notifications (user_id, kind, title, body, booking_id)
      values (new.renter_id, 'booking_expired', 'Reserva vencida',
              case when old.status = 'solicitada' then 'El propietario no respondió a tiempo.'
                   else 'Se venció el plazo para pagar.' end, new.id);
    when 'disputada' then
      insert into public.notifications (user_id, kind, title, body, booking_id) values
        (new.renter_id, 'booking_disputed', 'Reserva en revisión', 'Revisaremos lo ocurrido y te contactaremos.', new.id),
        (new.owner_id,  'booking_disputed', 'Reserva en revisión', 'Revisaremos lo ocurrido y te contactaremos.', new.id);
    else
      null;
  end case;
  return null;
end;
$$;

drop trigger if exists bookings_notify on public.bookings;
create trigger bookings_notify
  after insert or update of status on public.bookings
  for each row execute function public.notify_booking_change();

-- Aviso de mensaje nuevo (máximo uno cada 10 minutos por reserva para no hacer spam)
create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
  recipient uuid;
begin
  select * into b from public.bookings where id = new.booking_id;
  recipient := case when new.sender_id = b.owner_id then b.renter_id else b.owner_id end;
  if not exists (
    select 1 from public.notifications
    where user_id = recipient and booking_id = new.booking_id and kind = 'message'
      and created_at > now() - interval '10 minutes' and read_at is null
  ) then
    insert into public.notifications (user_id, kind, title, body, booking_id)
    values (recipient, 'message', 'Mensaje nuevo', left(new.body, 120), new.booking_id);
  end if;
  return null;
end;
$$;

drop trigger if exists messages_notify on public.messages;
create trigger messages_notify
  after insert on public.messages
  for each row execute function public.notify_new_message();

-- -----------------------------------------------------------------------------
-- Datos bancarios del propietario y pagos a propietarios
-- -----------------------------------------------------------------------------

create table if not exists public.payout_accounts (
  user_id         uuid primary key references public.profiles (id) on delete cascade,
  holder_name     text not null check (char_length(holder_name) between 3 and 80),
  holder_rut      text not null check (holder_rut ~ '^[0-9]{7,8}-[0-9Kk]$'),
  bank            text not null check (char_length(bank) between 2 and 60),
  account_type    text not null check (account_type in ('corriente', 'vista', 'ahorro', 'rut')),
  account_number  text not null check (account_number ~ '^[0-9-]{4,20}$'),
  email           text check (email is null or email ~ '^\S+@\S+\.\S+$'),
  updated_at      timestamptz not null default now()
);

create trigger payout_accounts_updated_at before update on public.payout_accounts
  for each row execute function public.set_updated_at();

alter table public.payout_accounts enable row level security;

create policy "payout_accounts: solo el dueño"
  on public.payout_accounts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.payout_accounts from anon;
grant select, insert, update, delete on public.payout_accounts to authenticated;

create table if not exists public.payouts (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null unique references public.bookings (id) on delete restrict,
  owner_id    uuid not null references public.profiles (id) on delete restrict,
  amount_clp  int not null check (amount_clp >= 0),
  status      text not null default 'pendiente' check (status in ('pendiente', 'pagado', 'retenido')),
  paid_at     timestamptz,
  reference   text,
  created_at  timestamptz not null default now()
);

alter table public.payouts enable row level security;

create policy "payouts: el propietario ve los suyos"
  on public.payouts for select to authenticated using (owner_id = auth.uid());

revoke all on public.payouts from anon;
revoke insert, update, delete on public.payouts from authenticated;
grant select on public.payouts to authenticated;

-- Al finalizar una reserva pagada se genera el pago pendiente al propietario.
create or replace function public.create_payout_on_finish()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'finalizada' and old.status is distinct from 'finalizada' and new.confirmed_at is not null then
    insert into public.payouts (booking_id, owner_id, amount_clp)
    values (new.id, new.owner_id, new.owner_payout_clp)
    on conflict (booking_id) do nothing;
  end if;
  return null;
end;
$$;

drop trigger if exists bookings_create_payout on public.bookings;
create trigger bookings_create_payout
  after update of status on public.bookings
  for each row execute function public.create_payout_on_finish();

-- -----------------------------------------------------------------------------
-- Reglas nuevas al solicitar: bloqueos y licencia (reemplaza request_booking de 0002)
-- -----------------------------------------------------------------------------

create or replace function public.request_booking(
  p_vehicle_id uuid,
  p_start date,
  p_end date,
  p_purpose public.booking_purpose default null,
  p_message text default null
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
begin
  if uid is null then
    raise exception 'Tienes que iniciar sesión' using errcode = '42501';
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

  return new_id;
end;
$$;

-- Búsqueda: oculta vehículos de personas bloqueadas (reemplaza search_vehicles de 0002)
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
-- Reservas: título del vehículo siempre visible para los participantes
-- (antes, si el vehículo se pausaba, el arrendatario dejaba de ver el título)
-- -----------------------------------------------------------------------------

create or replace function public.my_bookings(p_side text, p_limit int default 100)
returns table (
  id uuid, vehicle_id uuid, renter_id uuid, owner_id uuid, status public.booking_status,
  purpose public.booking_purpose, start_date date, end_date date, days int,
  total_clp int, owner_payout_clp int, created_at timestamptz,
  vehicle_title text, vehicle_type public.vehicle_type
)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, b.vehicle_id, b.renter_id, b.owner_id, b.status, b.purpose, b.start_date, b.end_date, b.days,
         b.total_clp, b.owner_payout_clp, b.created_at, v.title, v.vehicle_type
  from public.bookings b
  join public.vehicles v on v.id = b.vehicle_id
  where auth.uid() is not null
    and case when p_side = 'owner' then b.owner_id = auth.uid() else b.renter_id = auth.uid() end
  order by b.created_at desc
  limit least(greatest(p_limit, 1), 200)
$$;

create or replace function public.booking_vehicle(p_booking_id uuid)
returns table (vehicle_id uuid, title text, vehicle_type public.vehicle_type, city text, comuna text)
language sql
stable
security definer
set search_path = public
as $$
  select v.id, v.title, v.vehicle_type, v.city, v.comuna
  from public.bookings b join public.vehicles v on v.id = b.vehicle_id
  where b.id = p_booking_id and (b.owner_id = auth.uid() or b.renter_id = auth.uid())
$$;

-- -----------------------------------------------------------------------------
-- Eliminar cuenta (App Store / Google Play). Anonimiza y conserva el historial
-- contable mínimo que la ley exige. Lo llama la Edge Function delete-account,
-- que además elimina el usuario de Auth.
-- -----------------------------------------------------------------------------

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

  -- Cancela lo que aún no se paga
  perform set_config('rue.transition_note', 'Cuenta eliminada', true);
  update public.bookings set status = 'cancelada', cancelled_by = p_user_id, expires_at = null
   where (owner_id = p_user_id or renter_id = p_user_id) and status in ('solicitada', 'aceptada');
  perform set_config('rue.transition_note', '', true);

  -- Vehículos: se borran los que no tienen reservas; el resto queda pausado y anonimizado
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

-- -----------------------------------------------------------------------------
-- Permisos de ejecución
-- -----------------------------------------------------------------------------

revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.accept_terms(text) from public, anon;
revoke execute on function public.submit_verification(public.verification_kind, text, text) from public, anon;
revoke execute on function public.review_verification(uuid, boolean, text) from public, anon;
revoke execute on function public.assert_can_rent() from public, anon, authenticated;
revoke execute on function public.is_blocked_between(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.is_blocked_with(uuid) from public, anon;
revoke execute on function public.submit_review(uuid, int, text) from public, anon;
revoke execute on function public.user_reputation(uuid) from public, anon;
revoke execute on function public.notify_booking_change() from public, anon, authenticated;
revoke execute on function public.notify_new_message() from public, anon, authenticated;
revoke execute on function public.create_payout_on_finish() from public, anon, authenticated;
revoke execute on function public.my_bookings(text, int) from public, anon;
revoke execute on function public.booking_vehicle(uuid) from public, anon;
revoke execute on function public.delete_account_data(uuid) from public, anon, authenticated;
revoke execute on function public.request_booking(uuid, date, date, public.booking_purpose, text) from public, anon;
revoke execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) from public, anon;

grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_blocked_with(uuid) to authenticated;
grant execute on function public.accept_terms(text) to authenticated;
grant execute on function public.submit_verification(public.verification_kind, text, text) to authenticated;
grant execute on function public.review_verification(uuid, boolean, text) to authenticated, service_role;
grant execute on function public.submit_review(uuid, int, text) to authenticated;
grant execute on function public.user_reputation(uuid) to authenticated;
grant execute on function public.my_bookings(text, int) to authenticated;
grant execute on function public.booking_vehicle(uuid) to authenticated;
grant execute on function public.request_booking(uuid, date, date, public.booking_purpose, text) to authenticated;
grant execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) to authenticated;
grant execute on function public.delete_account_data(uuid) to service_role;
