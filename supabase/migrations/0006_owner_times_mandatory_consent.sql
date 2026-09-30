-- =============================================================================
-- RUÉ · 0006 · Decisiones del dueño (2026-10-01)
--
--   * Todos los tipos de vehículo (Términos ampliados → versión 2026-10-01).
--   * El precio se sigue calculando por días; el ARRENDADOR propone la hora de
--     entrega y de devolución al aceptar la solicitud (accept_booking). El
--     arrendatario las ve antes de pagar. Sin horas no se puede aceptar.
--   * Casilla C (comunicar datos al arrendador ante incidentes) es OBLIGATORIA
--     para reservar.
-- =============================================================================

update public.platform_settings set value = '"2026-10-01"', updated_at = now() where key = 'terms_version';

alter table public.bookings add column if not exists pickup_time time;
alter table public.bookings add column if not exists return_time time;

-- Las horas quedan fijas una vez pagada la reserva (se suman a los datos congelados).
create or replace function public.freeze_booking_times()
returns trigger
language plpgsql
as $$
begin
  if old.status not in ('solicitada', 'aceptada')
     and (new.pickup_time, new.return_time) is distinct from (old.pickup_time, old.return_time) then
    raise exception 'Las horas de una reserva pagada no se pueden cambiar' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_freeze_times on public.bookings;
create trigger bookings_freeze_times
  before update on public.bookings
  for each row execute function public.freeze_booking_times();

-- El propietario acepta proponiendo las horas. Reemplaza el uso directo de
-- transition_booking(..., 'aceptada'), que ahora exige horas definidas.
create or replace function public.accept_booking(p_booking_id uuid, p_pickup_time time, p_return_time time)
returns public.bookings
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
begin
  if p_pickup_time is null or p_return_time is null then
    raise exception 'Indica la hora de entrega y la de devolución' using errcode = '22023';
  end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.owner_id is distinct from auth.uid() then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  if b.status <> 'solicitada' then
    raise exception 'Esta solicitud ya no se puede aceptar' using errcode = 'P0001';
  end if;
  update public.bookings set pickup_time = p_pickup_time, return_time = p_return_time where id = b.id;
  return public.transition_booking(b.id, 'aceptada');
end;
$$;

-- transition_booking: aceptar exige horas (el resto igual que en 0005).
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
    if b.pickup_time is null or b.return_time is null then
      raise exception 'Para aceptar, propone la hora de entrega y la de devolución' using errcode = 'P0001';
    end if;
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

-- Aviso al arrendatario con las horas propuestas (reemplaza la versión de 0003).
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
      values (new.renter_id, 'booking_accepted', '¡Te aceptaron!',
              'Entrega a las ' || to_char(new.pickup_time, 'HH24:MI') || ' y devolución a las '
              || to_char(new.return_time, 'HH24:MI') || '. Paga para confirmar ' || vtitle || '.', new.id);
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

-- Casilla C obligatoria (reemplaza request_booking de 0005; misma firma).
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
  if not coalesce(p_accept_terms, false) or not coalesce(p_accept_data_sharing, false) then
    raise exception 'Para reservar debes aceptar los Términos y la autorización de comunicación de datos' using errcode = '22023';
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
  values (new_id, uid, current_terms, true, true);

  return new_id;
end;
$$;

-- my_bookings con horas (reemplaza la de 0003; cambia columnas, por eso se borra antes).
drop function if exists public.my_bookings(text, int);
create function public.my_bookings(p_side text, p_limit int default 100)
returns table (
  id uuid, vehicle_id uuid, renter_id uuid, owner_id uuid, status public.booking_status,
  purpose public.booking_purpose, start_date date, end_date date, days int,
  total_clp int, owner_payout_clp int, created_at timestamptz,
  vehicle_title text, vehicle_type public.vehicle_type,
  pickup_time time, return_time time
)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, b.vehicle_id, b.renter_id, b.owner_id, b.status, b.purpose, b.start_date, b.end_date, b.days,
         b.total_clp, b.owner_payout_clp, b.created_at, v.title, v.vehicle_type, b.pickup_time, b.return_time
  from public.bookings b
  join public.vehicles v on v.id = b.vehicle_id
  where auth.uid() is not null
    and case when p_side = 'owner' then b.owner_id = auth.uid() else b.renter_id = auth.uid() end
  order by b.created_at desc
  limit least(greatest(p_limit, 1), 200)
$$;

revoke execute on function public.accept_booking(uuid, time, time) from public, anon;
revoke execute on function public.freeze_booking_times() from public, anon, authenticated;
revoke execute on function public.my_bookings(text, int) from public, anon;
revoke execute on function public.transition_booking(uuid, public.booking_status, text) from public, anon;
revoke execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean) from public, anon;
grant execute on function public.accept_booking(uuid, time, time) to authenticated;
grant execute on function public.my_bookings(text, int) to authenticated;
grant execute on function public.transition_booking(uuid, public.booking_status, text) to authenticated;
grant execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean) to authenticated;
