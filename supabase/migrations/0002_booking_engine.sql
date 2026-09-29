-- =============================================================================
-- RUÉ · 0002 · Motor de reservas: precios, máquina de estados y búsqueda
--
-- Todo lo que involucra dinero o estados críticos vive aquí, en el servidor:
--   * compute_booking_price(): precio, cargo de servicio, comisión, payout.
--   * quote_booking():         cotización que la app solo muestra.
--   * request_booking():       crea la solicitud con montos congelados.
--   * transition_booking():    cambios de estado permitidos según quién eres.
--   * confirm_booking_payment(): SOLO servidor (webhook de Mercado Pago).
--   * expire_stale_bookings():   SOLO servidor (cron).
--   * Trigger que rechaza cualquier salto de estado inválido, venga de donde venga.
--   * search_vehicles():       búsqueda paginada con disponibilidad.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

create or replace function public.setting_numeric(p_key text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select (value #>> '{}')::numeric from public.platform_settings where key = p_key
$$;

-- Hoy en Chile (las reservas son por fecha local)
create or replace function public.today_cl()
returns date
language sql
stable
as $$
  select (now() at time zone 'America/Santiago')::date
$$;

-- ¿El vehículo está libre en [p_start, p_end)? Considera reservas activas y bloqueos.
create or replace function public.vehicle_is_available(
  p_vehicle_id uuid, p_start date, p_end date, p_exclude_booking uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from public.bookings b
    where b.vehicle_id = p_vehicle_id
      and b.status in ('aceptada', 'confirmada', 'en_curso', 'devuelta', 'disputada')
      and (p_exclude_booking is null or b.id <> p_exclude_booking)
      and daterange(b.start_date, b.end_date, '[)') && daterange(p_start, p_end, '[)')
  )
  and not exists (
    select 1 from public.vehicle_blocks k
    where k.vehicle_id = p_vehicle_id
      and daterange(k.start_date, k.end_date, '[)') && daterange(p_start, p_end, '[)')
  )
$$;

-- -----------------------------------------------------------------------------
-- Precio (única fuente de verdad)
-- -----------------------------------------------------------------------------

create or replace function public.compute_booking_price(p_vehicle_id uuid, p_start date, p_end date)
returns table (
  days                 int,
  rental_clp           int,
  renter_fee_clp       int,
  owner_commission_clp int,
  total_clp            int,
  owner_payout_clp     int,
  deposit_clp          int
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v        public.vehicles%rowtype;
  n_days   int;
  rental   int;
  fee_pct  numeric := coalesce(public.setting_numeric('renter_service_fee_pct'), 0);
  com_pct  numeric := coalesce(public.setting_numeric('owner_commission_pct'), 0);
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;

  n_days := p_end - p_start;
  if n_days <= 0 then
    raise exception 'La fecha de término debe ser posterior a la de inicio' using errcode = '22023';
  end if;

  rental := n_days * v.daily_price_clp;
  if v.weekly_price_clp is not null and n_days >= 7 then
    rental := least(rental, (n_days / 7) * v.weekly_price_clp + (n_days % 7) * v.daily_price_clp);
  end if;

  days                 := n_days;
  rental_clp           := rental;
  renter_fee_clp       := round(rental * fee_pct / 100.0)::int;
  owner_commission_clp := round(rental * com_pct / 100.0)::int;
  total_clp            := rental + renter_fee_clp;
  owner_payout_clp     := rental - owner_commission_clp;
  deposit_clp          := v.deposit_clp;
  return next;
end;
$$;

-- Validaciones comunes de fechas para una nueva reserva
create or replace function public.assert_bookable(p_vehicle public.vehicles, p_start date, p_end date)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  max_days int := coalesce(public.setting_numeric('max_booking_days'), 90)::int;
begin
  if p_vehicle.status <> 'publicado' then
    raise exception 'Este vehículo no está publicado' using errcode = 'P0001';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception 'Revisa las fechas: el término debe ser después del inicio' using errcode = '22023';
  end if;
  if p_start < public.today_cl() then
    raise exception 'La fecha de inicio no puede ser en el pasado' using errcode = '22023';
  end if;
  if (p_end - p_start) < p_vehicle.min_days then
    raise exception 'Este vehículo se arrienda por mínimo % días', p_vehicle.min_days using errcode = '22023';
  end if;
  if (p_end - p_start) > max_days then
    raise exception 'Una reserva puede durar máximo % días', max_days using errcode = '22023';
  end if;
  if not public.vehicle_is_available(p_vehicle.id, p_start, p_end) then
    raise exception 'Este vehículo no está disponible para esas fechas' using errcode = 'P0001';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Cotización (la app la muestra, no la calcula)
-- -----------------------------------------------------------------------------

create or replace function public.quote_booking(p_vehicle_id uuid, p_start date, p_end date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.vehicles%rowtype;
  p record;
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found or (v.status <> 'publicado' and v.owner_id is distinct from auth.uid()) then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;

  perform public.assert_bookable(v, p_start, p_end);
  select * into p from public.compute_booking_price(p_vehicle_id, p_start, p_end);

  return jsonb_build_object(
    'days', p.days,
    'rental_clp', p.rental_clp,
    'renter_fee_clp', p.renter_fee_clp,
    'total_clp', p.total_clp,
    'deposit_clp', p.deposit_clp
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Solicitar reserva
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

-- -----------------------------------------------------------------------------
-- Máquina de estados
-- -----------------------------------------------------------------------------

-- Grafo global de transiciones válidas (independiente de quién la pide)
create or replace function public.booking_transition_allowed(p_from public.booking_status, p_to public.booking_status)
returns boolean
language sql
immutable
as $$
  select (p_from, p_to) in (
    ('solicitada', 'aceptada'),   ('solicitada', 'rechazada'),
    ('solicitada', 'cancelada'),  ('solicitada', 'vencida'),
    ('aceptada',   'confirmada'), ('aceptada',   'cancelada'),  ('aceptada', 'vencida'),
    ('confirmada', 'en_curso'),   ('confirmada', 'cancelada'),
    ('en_curso',   'devuelta'),   ('en_curso',   'disputada'),
    ('devuelta',   'finalizada'), ('devuelta',   'disputada'),
    ('disputada',  'finalizada'), ('disputada',  'cancelada')
  )
$$;

-- Trigger: nadie (ni siquiera el servidor) puede saltarse el grafo
create or replace function public.enforce_booking_transition()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if not public.booking_transition_allowed(old.status, new.status) then
      raise exception 'Cambio de estado no permitido: % → %', old.status, new.status
        using errcode = 'P0001';
    end if;

    case new.status
      when 'aceptada'   then new.accepted_at  := coalesce(new.accepted_at, now());
      when 'confirmada' then new.confirmed_at := coalesce(new.confirmed_at, now());
      when 'en_curso'   then new.started_at   := coalesce(new.started_at, now());
      when 'devuelta'   then new.returned_at  := coalesce(new.returned_at, now());
      when 'finalizada' then new.finished_at  := coalesce(new.finished_at, now());
      when 'cancelada'  then new.cancelled_at := coalesce(new.cancelled_at, now());
      else null;
    end case;
  end if;

  -- Los montos y las partes quedan congelados después de crear la reserva.
  if (new.vehicle_id, new.renter_id, new.owner_id, new.start_date, new.end_date, new.days,
      new.rental_clp, new.renter_fee_clp, new.owner_commission_clp, new.total_clp,
      new.owner_payout_clp, new.deposit_clp)
     is distinct from
     (old.vehicle_id, old.renter_id, old.owner_id, old.start_date, old.end_date, old.days,
      old.rental_clp, old.renter_fee_clp, old.owner_commission_clp, old.total_clp,
      old.owner_payout_clp, old.deposit_clp) then
    raise exception 'Los datos económicos de una reserva no se pueden modificar' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists bookings_enforce_transition on public.bookings;
create trigger bookings_enforce_transition
  before update on public.bookings
  for each row execute function public.enforce_booking_transition();

-- Auditoría automática de cada estado
create or replace function public.log_booking_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.booking_events (booking_id, from_status, to_status, actor_id)
    values (new.id, null, new.status, auth.uid());
  elsif new.status is distinct from old.status then
    insert into public.booking_events (booking_id, from_status, to_status, actor_id, note)
    values (new.id, old.status, new.status, auth.uid(),
            nullif(current_setting('rue.transition_note', true), ''));
  end if;
  return null;
end;
$$;

drop trigger if exists bookings_log_event on public.bookings;
create trigger bookings_log_event
  after insert or update of status on public.bookings
  for each row execute function public.log_booking_event();

-- Cambios de estado pedidos por la app. Permisos según rol.
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

  -- Qué puede hacer cada parte. 'confirmada' NUNCA desde la app: solo el pago.
  -- 'confirmada' → 'cancelada' tampoco: implica reembolso (pendiente de política).
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

  if p_to = 'en_curso' and public.today_cl() < b.start_date then
    raise exception 'La entrega se puede marcar desde el %', to_char(b.start_date, 'DD-MM-YYYY')
      using errcode = 'P0001';
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

  -- Al aceptar, las otras solicitudes que se cruzan quedan rechazadas.
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
-- Solo servidor: confirmación por pago (la llama el webhook de Mercado Pago)
-- Idempotente: llamarla dos veces con el mismo pago no hace nada la segunda vez.
-- -----------------------------------------------------------------------------

create or replace function public.confirm_booking_payment(
  p_booking_id uuid,
  p_provider_payment_id text,
  p_amount_clp int,
  p_environment text
)
returns text   -- 'confirmed' | 'already_confirmed' | 'amount_mismatch' | 'not_payable'
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;

  insert into public.payments (booking_id, environment, provider_payment_id, status, amount_clp)
  values (b.id, p_environment, p_provider_payment_id, 'approved', p_amount_clp)
  on conflict (provider, provider_payment_id)
  do update set status = 'approved';

  if b.status in ('confirmada', 'en_curso', 'devuelta', 'finalizada', 'disputada') then
    return 'already_confirmed';
  end if;

  if p_amount_clp <> b.total_clp then
    return 'amount_mismatch';
  end if;

  if b.status <> 'aceptada' then
    -- Pagó una reserva vencida/cancelada: requiere revisión y reembolso manual.
    return 'not_payable';
  end if;

  perform set_config('rue.transition_note', 'Pago aprobado ' || p_provider_payment_id, true);
  update public.bookings set status = 'confirmada', expires_at = null where id = b.id;
  perform set_config('rue.transition_note', '', true);
  return 'confirmed';
end;
$$;

-- Solo servidor: vence solicitudes sin respuesta y reservas aceptadas sin pago.
create or replace function public.expire_stale_bookings()
returns int
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n int;
begin
  perform set_config('rue.transition_note', 'Venció el plazo', true);
  update public.bookings
     set status = 'vencida', expires_at = null
   where status in ('solicitada', 'aceptada')
     and expires_at is not null
     and expires_at < now();
  get diagnostics n = row_count;
  perform set_config('rue.transition_note', '', true);
  return n;
end;
$$;

-- -----------------------------------------------------------------------------
-- Búsqueda paginada
-- -----------------------------------------------------------------------------

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
-- Permisos de ejecución
-- -----------------------------------------------------------------------------

revoke execute on function public.setting_numeric(text) from public, anon, authenticated;
revoke execute on function public.vehicle_is_available(uuid, date, date, uuid) from public, anon, authenticated;
revoke execute on function public.compute_booking_price(uuid, date, date) from public, anon, authenticated;
revoke execute on function public.assert_bookable(public.vehicles, date, date) from public, anon, authenticated;
revoke execute on function public.confirm_booking_payment(uuid, text, int, text) from public, anon, authenticated;
revoke execute on function public.expire_stale_bookings() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.log_booking_event() from public, anon, authenticated;

revoke execute on function public.quote_booking(uuid, date, date) from public, anon;
revoke execute on function public.request_booking(uuid, date, date, public.booking_purpose, text) from public, anon;
revoke execute on function public.transition_booking(uuid, public.booking_status, text) from public, anon;
revoke execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) from public, anon;

grant execute on function public.quote_booking(uuid, date, date) to authenticated;
grant execute on function public.request_booking(uuid, date, date, public.booking_purpose, text) to authenticated;
grant execute on function public.transition_booking(uuid, public.booking_status, text) to authenticated;
grant execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) to authenticated;

grant execute on function public.confirm_booking_payment(uuid, text, int, text) to service_role;
grant execute on function public.expire_stale_bookings() to service_role;
