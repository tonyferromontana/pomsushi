-- =============================================================================
-- RUÉ · 0009 · Marketplace transaccional completo (principio de producto 2026-10-01)
--
-- Discovery → Offer → Negotiation → Booking → Payment → Verification →
-- Digital agreement → Check-in → Active rental → Extension → Check-out →
-- Damage/Dispute → Payout → Review.
--
--   * Negociación tipo inDrive: offer_rules (versionadas) calculan precio
--     recomendado y mínimo permitido (propiedad de RUÉ, no se expone el número);
--     booking_offers registra cada oferta (máx. rondas configurable, hoy 3).
--   * Precio acordado: price_booking() (reemplaza el cálculo de compute_booking_price);
--     la reserva se re-precia SOLO antes de aceptarse y queda en el snapshot.
--   * Desintermediación: el chat oculta teléfonos/correos/links antes de la
--     confirmación y marca para revisión señales de pago por fuera (message_flags).
--     Las publicaciones y perfiles no aceptan datos de contacto.
--   * Check-in / check-out: daños estructurados, ubicación opcional, confirmación
--     de ambas partes, estructura para análisis futuro (OCR, comparación de fotos).
--   * Contrato digital por reserva y anexo por extensión (booking_agreements, con hash).
--   * Extensiones: solicitud → aprobación del propietario → pago Webpay → aplicada,
--     con su propio snapshot y partidas de ledger. Nunca se modifica en silencio.
--   * Trust layer: user_trust() y vehicle_trust() (sin datos privados).
--   * Repeat transactions: historial de la pareja guardado en el snapshot.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Reglas de oferta (precio recomendado y mínimo permitido)
-- -----------------------------------------------------------------------------

create table if not exists public.offer_rules (
  id                       bigint generated always as identity primary key,
  vehicle_type             public.vehicle_type,           -- null = todos los tipos
  min_ratio                numeric(5,4) not null check (min_ratio > 0 and min_ratio <= 1),
  recommended_low_ratio    numeric(5,4) not null check (recommended_low_ratio > 0),
  recommended_high_ratio   numeric(5,4) not null check (recommended_high_ratio >= recommended_low_ratio),
  rounding_clp             int not null default 1000 check (rounding_clp between 1 and 100000),
  max_rounds               int not null default 3 check (max_rounds between 1 and 10),
  offer_ttl_hours          int not null default 24 check (offer_ttl_hours between 1 and 168),
  -- Futuro: valor del activo, duración, ubicación, demanda, disponibilidad, temporada,
  -- riesgo, reglas del propietario. Hoy solo reglas sin condiciones ('{}').
  conditions               jsonb not null default '{}'::jsonb check (jsonb_typeof(conditions) = 'object'),
  priority                 int not null default 0,
  version                  text not null,
  effective_from           timestamptz not null default clock_timestamp(),
  notes                    text,
  created_by               uuid,
  created_at               timestamptz not null default clock_timestamp()
);

alter table public.offer_rules enable row level security;
revoke all on public.offer_rules from anon, authenticated;
grant select on public.offer_rules to service_role;

drop trigger if exists offer_rules_immutable on public.offer_rules;
create trigger offer_rules_immutable
  before update or delete on public.offer_rules
  for each row execute function public.forbid_update_delete();

-- Provisorio, derivado del ejemplo del dueño: publicado 55.000 → recomendado
-- 52.000–58.000, mínimo 45.000 (82 %). Ajustable publicando otra versión.
insert into public.offer_rules (vehicle_type, min_ratio, recommended_low_ratio, recommended_high_ratio,
                                rounding_clp, max_rounds, offer_ttl_hours, version, effective_from, notes)
select null, 0.82, 0.95, 1.05, 1000, 3, 24, 'mvp-2026-10-01', '2026-10-01 00:00:00-03',
       'MVP provisorio: mínimo 82 % del precio publicado, recomendado ±5 %, redondeo a $1.000, 3 rondas, 24 h por oferta.'
where not exists (select 1 from public.offer_rules where version = 'mvp-2026-10-01');

create or replace function public.resolve_offer_rule(p_vehicle_type public.vehicle_type, p_context jsonb default '{}'::jsonb)
returns public.offer_rules
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.offer_rules;
begin
  select * into r from public.offer_rules o
  where (o.vehicle_type is null or o.vehicle_type = p_vehicle_type)
    and o.effective_from <= clock_timestamp()
    and public.guarantee_rule_matches(o.conditions, coalesce(p_context, '{}'::jsonb))
  order by (o.vehicle_type is not null) desc, o.priority desc, o.effective_from desc, o.id desc
  limit 1;
  if r.id is null then
    raise exception 'No hay reglas de oferta vigentes' using errcode = 'P0001';
  end if;
  return r;
end;
$$;

create or replace function public.publish_offer_rule(
  p_vehicle_type public.vehicle_type, p_min_ratio numeric, p_low numeric, p_high numeric,
  p_max_rounds int, p_offer_ttl_hours int, p_version text, p_notes text
)
returns bigint
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  new_id bigint;
begin
  perform public.assert_admin_or_server();
  if coalesce(btrim(p_notes), '') = '' then
    raise exception 'Explica el motivo del cambio en las notas' using errcode = '22023';
  end if;
  insert into public.offer_rules (vehicle_type, min_ratio, recommended_low_ratio, recommended_high_ratio,
                                  max_rounds, offer_ttl_hours, version, notes, created_by)
  values (p_vehicle_type, p_min_ratio, p_low, p_high, p_max_rounds, p_offer_ttl_hours, p_version, p_notes, auth.uid())
  returning id into new_id;
  return new_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Precio con tarifa acordada (reemplaza el cuerpo de compute_booking_price)
-- -----------------------------------------------------------------------------

create or replace function public.round_to(p_value numeric, p_step int)
returns int
language sql
immutable
as $$
  select (round(p_value / greatest(p_step, 1)) * greatest(p_step, 1))::int
$$;

create or replace function public.price_booking(p_vehicle_id uuid, p_start date, p_end date, p_agreed_daily_clp int default null)
returns table (
  days                       int,
  rental_clp                 int,
  rental_extras_clp          int,
  gmv_clp                    int,
  renter_fee_clp             int,
  owner_commission_clp       int,
  total_clp                  int,
  owner_payout_clp           int,
  deposit_clp                int,
  platform_gross_revenue_clp int,
  economic_config_id         bigint,
  guarantee_rule_id          bigint,
  pricing_snapshot           jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v         public.vehicles%rowtype;
  cfg       public.economic_config_versions%rowtype;
  g         record;
  n_days    int;
  published int;
  rental    int;
  extras    int := 0;
  ctx       jsonb;
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;
  n_days := p_end - p_start;
  if n_days <= 0 then
    raise exception 'La fecha de término debe ser posterior a la de inicio' using errcode = '22023';
  end if;
  if p_agreed_daily_clp is not null and p_agreed_daily_clp <= 0 then
    raise exception 'Precio no válido' using errcode = '22023';
  end if;

  cfg := public.active_economic_config();
  if cfg.id is null then
    raise exception 'No hay configuración económica vigente' using errcode = 'P0001';
  end if;
  if cfg.tax_treatment <> 'pending_accountant' then
    raise exception 'Tratamiento tributario % aún no implementado', cfg.tax_treatment using errcode = 'P0001';
  end if;

  published := n_days * v.daily_price_clp;
  if v.weekly_price_clp is not null and n_days >= 7 then
    published := least(published, (n_days / 7) * v.weekly_price_clp + (n_days % 7) * v.daily_price_clp);
  end if;
  rental := coalesce(n_days * p_agreed_daily_clp, published);

  ctx := jsonb_build_object('vehicle_type', v.vehicle_type, 'days', n_days, 'vehicle_year', v.year, 'vehicle_verified', v.verified);
  select * into g from public.resolve_guarantee(v.vehicle_type, ctx);

  days                       := n_days;
  rental_clp                 := rental;
  rental_extras_clp          := extras;
  gmv_clp                    := rental + extras;
  renter_fee_clp             := round((rental + extras) * cfg.renter_service_fee_rate)::int;
  owner_commission_clp       := round((rental + extras) * cfg.owner_fee_rate)::int;
  total_clp                  := rental + extras + renter_fee_clp;
  owner_payout_clp           := rental + extras - owner_commission_clp;
  deposit_clp                := g.amount_clp;
  platform_gross_revenue_clp := renter_fee_clp + owner_commission_clp;
  economic_config_id         := cfg.id;
  guarantee_rule_id          := g.rule_id;
  pricing_snapshot := jsonb_build_object(
    'pricing_version', 'rue-pricing-2',
    'computed_at', clock_timestamp(),
    'inputs', jsonb_build_object(
      'vehicle_id', v.id, 'vehicle_type', v.vehicle_type,
      'daily_price_clp', v.daily_price_clp, 'weekly_price_clp', v.weekly_price_clp,
      'start_date', p_start, 'end_date', p_end, 'days', n_days, 'city', v.city, 'comuna', v.comuna
    ),
    'negotiation', jsonb_build_object(
      'published_rental_clp', published,
      'published_daily_clp', round(published::numeric / n_days)::int,
      'agreed_daily_clp', p_agreed_daily_clp
    ),
    'economic_config', jsonb_build_object(
      'id', cfg.id, 'version', cfg.version,
      'owner_fee_rate', cfg.owner_fee_rate, 'renter_service_fee_rate', cfg.renter_service_fee_rate,
      'fee_base', cfg.fee_base, 'tax_treatment', cfg.tax_treatment,
      'payout_delay_business_days', cfg.payout_delay_business_days
    ),
    'guarantee', jsonb_build_object('rule_id', g.rule_id, 'rule_version', g.rule_version, 'amount_clp', g.amount_clp, 'context', ctx),
    'outputs', jsonb_build_object(
      'rental_base_clp', rental, 'rental_extras_clp', extras, 'gmv_clp', rental + extras,
      'owner_fee_clp', owner_commission_clp, 'renter_service_fee_clp', renter_fee_clp,
      'charged_clp', total_clp, 'owner_payout_clp', owner_payout_clp,
      'guarantee_clp', g.amount_clp, 'platform_gross_revenue_clp', platform_gross_revenue_clp,
      'tax_clp', null
    )
  );
  return next;
end;
$$;

create or replace function public.compute_booking_price(p_vehicle_id uuid, p_start date, p_end date)
returns table (
  days int, rental_clp int, rental_extras_clp int, gmv_clp int, renter_fee_clp int, owner_commission_clp int,
  total_clp int, owner_payout_clp int, deposit_clp int, platform_gross_revenue_clp int,
  economic_config_id bigint, guarantee_rule_id bigint, pricing_snapshot jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select * from public.price_booking(p_vehicle_id, p_start, p_end, null)
$$;

-- Guía de precio para ofertas (por día). El mínimo NO se expone a la app.
create or replace function public.price_guidance(p_vehicle_id uuid, p_start date, p_end date)
returns table (published_daily_clp int, recommended_low_clp int, recommended_high_clp int,
               minimum_clp int, offer_rule_id bigint, max_rounds int, offer_ttl_hours int)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.vehicles%rowtype;
  r public.offer_rules;
  n int := p_end - p_start;
  pub int;
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found or n <= 0 then
    raise exception 'Vehículo o fechas no válidos' using errcode = '22023';
  end if;
  pub := n * v.daily_price_clp;
  if v.weekly_price_clp is not null and n >= 7 then
    pub := least(pub, (n / 7) * v.weekly_price_clp + (n % 7) * v.daily_price_clp);
  end if;
  pub := round(pub::numeric / n)::int;
  r := public.resolve_offer_rule(v.vehicle_type, jsonb_build_object('days', n, 'vehicle_type', v.vehicle_type));
  published_daily_clp  := pub;
  recommended_low_clp  := public.round_to(pub * r.recommended_low_ratio, r.rounding_clp);
  recommended_high_clp := public.round_to(pub * r.recommended_high_ratio, r.rounding_clp);
  minimum_clp          := greatest(public.round_to(pub * r.min_ratio, r.rounding_clp), 1);
  offer_rule_id        := r.id;
  max_rounds           := r.max_rounds;
  offer_ttl_hours      := r.offer_ttl_hours;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Ofertas
-- -----------------------------------------------------------------------------

create table if not exists public.booking_offers (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references public.bookings (id) on delete cascade,
  sender_id      uuid not null references public.profiles (id),
  recipient_id   uuid not null references public.profiles (id),
  amount_clp     int not null check (amount_clp > 0),
  price_unit     text not null default 'day' check (price_unit in ('day')),
  currency       text not null default 'CLP' check (currency = 'CLP'),
  status         text not null default 'pending'
                 check (status in ('pending', 'accepted', 'rejected', 'countered', 'expired', 'cancelled')),
  round_number   int not null check (round_number between 1 and 10),
  max_rounds     int not null check (max_rounds between 1 and 10),   -- según la regla vigente al abrir la negociación
  pickup_time    time,   -- la contraoferta del propietario incluye las horas
  return_time    time,
  offer_rule_id  bigint references public.offer_rules (id),
  expires_at     timestamptz not null,
  responded_at   timestamptz,
  created_at     timestamptz not null default clock_timestamp(),
  constraint booking_offers_round_unique unique (booking_id, round_number),
  constraint booking_offers_parties check (sender_id <> recipient_id)
);

-- Nunca dos ofertas abiertas a la vez en la misma negociación.
create unique index if not exists booking_offers_one_pending on public.booking_offers (booking_id) where status = 'pending';

alter table public.booking_offers enable row level security;

create policy "booking_offers: participantes leen"
  on public.booking_offers for select to authenticated
  using (sender_id = auth.uid() or recipient_id = auth.uid());

revoke all on public.booking_offers from anon;
revoke insert, update, delete on public.booking_offers from authenticated;
grant select on public.booking_offers to authenticated;

-- Valida una oferta contra las reglas (mínimo, máximo = publicado).
create or replace function public.assert_valid_offer(p_vehicle_id uuid, p_start date, p_end date, p_amount int)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  gd record;
begin
  select * into gd from public.price_guidance(p_vehicle_id, p_start, p_end);
  if p_amount is null or p_amount < gd.minimum_clp then
    raise exception 'Esta oferta está bajo el mínimo permitido.' using errcode = 'P0001';
  end if;
  if p_amount > gd.published_daily_clp then
    raise exception 'La oferta no puede superar el precio publicado.' using errcode = '22023';
  end if;
end;
$$;

-- Re-precio antes de aceptar (única ventana en que cambian los montos).
create or replace function public.reprice_booking(p_booking_id uuid, p_daily int, p_offer_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
  p record;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if b.status <> 'solicitada' then
    raise exception 'La reserva ya no se puede re-preciar' using errcode = 'P0001';
  end if;
  select * into p from public.price_booking(b.vehicle_id, b.start_date, b.end_date, p_daily);
  perform set_config('rue.reprice', 'on', true);
  update public.bookings
     set rental_clp = p.rental_clp, rental_extras_clp = p.rental_extras_clp, gmv_clp = p.gmv_clp,
         renter_fee_clp = p.renter_fee_clp, owner_commission_clp = p.owner_commission_clp,
         total_clp = p.total_clp, owner_payout_clp = p.owner_payout_clp, deposit_clp = p.deposit_clp,
         platform_gross_revenue_clp = p.platform_gross_revenue_clp,
         economic_config_id = p.economic_config_id, guarantee_rule_id = p.guarantee_rule_id,
         pricing_snapshot = p.pricing_snapshot
           || jsonb_build_object('relationship', b.pricing_snapshot -> 'relationship')
           || jsonb_build_object('negotiation', (p.pricing_snapshot -> 'negotiation')
                || jsonb_build_object('accepted_offer_id', p_offer_id,
                     'accepted_round', (select round_number from public.booking_offers where id = p_offer_id)))
   where id = b.id;
  perform set_config('rue.reprice', '', true);
end;
$$;

-- Congelamiento (reemplaza 0008): montos solo cambian al re-preciar una solicitud;
-- la fecha de término solo se alarga por una extensión pagada.
create or replace function public.enforce_booking_transition()
returns trigger
language plpgsql
as $$
declare
  repricing boolean := coalesce(current_setting('rue.reprice', true), '') = 'on' and old.status = 'solicitada';
  extending boolean := coalesce(current_setting('rue.extension', true), '') = 'on' and new.end_date > old.end_date
                       and old.status in ('confirmada', 'en_curso');
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

  if (new.vehicle_id, new.renter_id, new.owner_id, new.start_date, new.days)
     is distinct from (old.vehicle_id, old.renter_id, old.owner_id, old.start_date, old.days)
     or (new.end_date is distinct from old.end_date and not extending)
     or (not repricing and
         (new.rental_clp, new.rental_extras_clp, new.gmv_clp, new.renter_fee_clp, new.owner_commission_clp,
          new.total_clp, new.owner_payout_clp, new.deposit_clp, new.platform_gross_revenue_clp,
          new.economic_config_id, new.guarantee_rule_id, new.pricing_snapshot)
         is distinct from
         (old.rental_clp, old.rental_extras_clp, old.gmv_clp, old.renter_fee_clp, old.owner_commission_clp,
          old.total_clp, old.owner_payout_clp, old.deposit_clp, old.platform_gross_revenue_clp,
          old.economic_config_id, old.guarantee_rule_id, old.pricing_snapshot)) then
    raise exception 'Los datos económicos de una reserva no se pueden modificar' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

-- Aceptación común (propietario acepta o arrendatario acepta la contraoferta).
create or replace function public.finalize_acceptance(p_booking_id uuid)
returns public.bookings
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if b.status <> 'solicitada' then
    raise exception 'Esta solicitud ya no se puede aceptar' using errcode = 'P0001';
  end if;
  if b.pickup_time is null or b.return_time is null then
    raise exception 'Falta la hora de entrega y de devolución' using errcode = 'P0001';
  end if;
  if b.expires_at is not null and b.expires_at < now() then
    raise exception 'Esta solicitud ya venció' using errcode = 'P0001';
  end if;
  if b.start_date < public.today_cl() then
    raise exception 'La fecha de inicio ya pasó' using errcode = 'P0001';
  end if;
  if not public.vehicle_is_available(b.vehicle_id, b.start_date, b.end_date, b.id) then
    raise exception 'El vehículo ya no está disponible para esas fechas' using errcode = 'P0001';
  end if;

  update public.booking_offers set status = 'cancelled', responded_at = now()
   where booking_id = b.id and status = 'pending';

  update public.bookings
     set status = 'aceptada',
         expires_at = now() + make_interval(hours => coalesce(public.setting_numeric('payment_expiry_hours'), 24)::int)
   where id = b.id
   returning * into b;

  perform set_config('rue.transition_note', 'Rechazada automáticamente: el vehículo se reservó para esas fechas', true);
  update public.bookings o
     set status = 'rechazada', expires_at = null
   where o.vehicle_id = b.vehicle_id and o.id <> b.id and o.status = 'solicitada'
     and daterange(o.start_date, o.end_date, '[)') && daterange(b.start_date, b.end_date, '[)');
  perform set_config('rue.transition_note', '', true);
  return b;
exception
  when exclusion_violation then
    raise exception 'El vehículo ya no está disponible para esas fechas' using errcode = 'P0001';
end;
$$;

-- El propietario acepta (al precio publicado o a la oferta pendiente del arrendatario).
create or replace function public.accept_booking(p_booking_id uuid, p_pickup_time time, p_return_time time)
returns public.bookings
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
  o public.booking_offers%rowtype;
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
  select * into o from public.booking_offers where booking_id = b.id and status = 'pending' for update;
  if found then
    if o.recipient_id <> b.owner_id then
      raise exception 'Estás esperando la respuesta del arrendatario a tu contraoferta' using errcode = 'P0001';
    end if;
    perform public.reprice_booking(b.id, o.amount_clp, o.id);
    update public.booking_offers set status = 'accepted', responded_at = now() where id = o.id;
  end if;
  update public.bookings set pickup_time = p_pickup_time, return_time = p_return_time where id = b.id;
  return public.finalize_acceptance(b.id);
end;
$$;

-- Contraoferta (quien recibe la oferta pendiente). La del propietario incluye horas.
create or replace function public.counter_offer(p_booking_id uuid, p_amount_clp int, p_pickup_time time default null, p_return_time time default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  b   public.bookings%rowtype;
  o   public.booking_offers%rowtype;
  gd  record;
  new_id uuid;
  exp timestamptz;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or uid is null or (b.owner_id <> uid and b.renter_id <> uid) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  if b.status <> 'solicitada' then
    raise exception 'Esta negociación ya terminó' using errcode = 'P0001';
  end if;
  select * into o from public.booking_offers where booking_id = b.id and status = 'pending' for update;
  if not found or o.recipient_id <> uid then
    raise exception 'No tienes una oferta por responder' using errcode = 'P0001';
  end if;
  if o.expires_at < now() then
    raise exception 'Esta oferta ya venció' using errcode = 'P0001';
  end if;
  perform public.assert_valid_offer(b.vehicle_id, b.start_date, b.end_date, p_amount_clp);
  select * into gd from public.price_guidance(b.vehicle_id, b.start_date, b.end_date);
  if o.round_number >= o.max_rounds then
    raise exception 'Se llegó al máximo de % rondas: solo puedes aceptar o rechazar', o.max_rounds using errcode = 'P0001';
  end if;
  if p_amount_clp = o.amount_clp then
    raise exception 'Para ese precio, acepta la oferta' using errcode = '22023';
  end if;
  if uid = b.owner_id and (p_pickup_time is null or p_return_time is null) then
    raise exception 'Indica la hora de entrega y la de devolución' using errcode = '22023';
  end if;
  if uid = b.renter_id then
    perform public.assert_can_rent();
  end if;
  if not public.vehicle_is_available(b.vehicle_id, b.start_date, b.end_date, b.id) then
    raise exception 'El vehículo ya no está disponible para esas fechas' using errcode = 'P0001';
  end if;

  exp := now() + make_interval(hours => gd.offer_ttl_hours);
  update public.booking_offers set status = 'countered', responded_at = now() where id = o.id;
  insert into public.booking_offers (booking_id, sender_id, recipient_id, amount_clp, round_number, max_rounds,
                                     pickup_time, return_time, offer_rule_id, expires_at)
  values (b.id, uid, o.sender_id, p_amount_clp, o.round_number + 1, o.max_rounds,
          case when uid = b.owner_id then p_pickup_time end, case when uid = b.owner_id then p_return_time end,
          o.offer_rule_id, exp)
  returning id into new_id;
  update public.bookings set expires_at = greatest(coalesce(expires_at, exp), exp) where id = b.id;

  insert into public.notifications (user_id, kind, title, body, booking_id)
  values (o.sender_id, 'offer_countered', 'Te hicieron una contraoferta',
          'Nueva propuesta: ' || to_char(p_amount_clp, 'FM999G999G999') || ' por día. Respóndela antes de que venza.', b.id);
  return new_id;
end;
$$;

-- El arrendatario acepta la contraoferta del propietario (queda aceptada y lista para pagar).
create or replace function public.accept_offer(p_booking_id uuid)
returns public.bookings
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
  o public.booking_offers%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.renter_id is distinct from auth.uid() then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  select * into o from public.booking_offers where booking_id = b.id and status = 'pending' for update;
  if not found or o.recipient_id <> b.renter_id then
    raise exception 'No tienes una contraoferta por aceptar' using errcode = 'P0001';
  end if;
  if o.expires_at < now() then
    raise exception 'Esta oferta ya venció' using errcode = 'P0001';
  end if;
  perform public.assert_can_rent();
  perform public.reprice_booking(b.id, o.amount_clp, o.id);
  update public.booking_offers set status = 'accepted', responded_at = now() where id = o.id;
  update public.bookings set pickup_time = o.pickup_time, return_time = o.return_time where id = b.id;
  return public.finalize_acceptance(b.id);
end;
$$;

-- Al terminar la negociación por otra vía, las ofertas abiertas se cierran.
create or replace function public.close_offers_on_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is not distinct from old.status or old.status <> 'solicitada' then
    return null;
  end if;
  update public.booking_offers
     set status = case new.status when 'rechazada' then 'rejected' when 'vencida' then 'expired' else 'cancelled' end,
         responded_at = now()
   where booking_id = new.id and status = 'pending';
  return null;
end;
$$;

drop trigger if exists bookings_close_offers on public.bookings;
create trigger bookings_close_offers
  after update of status on public.bookings
  for each row execute function public.close_offers_on_booking_change();

-- -----------------------------------------------------------------------------
-- 4. Datos de contacto y señales de transacción por fuera
-- -----------------------------------------------------------------------------

create or replace function public.contact_signals(p_text text)
returns text[]
language sql
immutable
as $$
  select array_remove(array[
    case when p_text ~ '(\+\s*\d{1,3}([\s.()-]*\d){7,})|((56[\s.-]*)?9[\s.-]*\d{4}[\s.-]*\d{4})' then 'phone' end,
    case when p_text ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' then 'email' end,
    case when p_text ~* '(https?://|www\.)\S+|\m(wa\.me|t\.me|bit\.ly)/' then 'link' end,
    case when p_text ~* '\m(whats?app|wsp|wasap|guasap|watsap|wpp|telegram)\M' then 'messaging_app' end,
    case when p_text ~* '(transferencia|transfi[eé]r|mercado\s*pago|cuenta\s*rut|efectivo|p[aá]g(a|ue)me\s+(afuera|por\s+fuera|directo)|por\s+fuera|fuera\s+de\s+(la\s+)?app|sin\s+(la\s+)?app|sin\s+comisi[oó]n)' then 'off_platform_payment' end,
    case when p_text ~* '(te\s+hago\s+(un\s+)?descuento|descuento\s+si)' then 'discount_outside' end
  ], null)
$$;

create or replace function public.mask_contact_data(p_text text)
returns text
language sql
immutable
as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(p_text,
               '(\+\s*\d{1,3}([\s.()-]*\d){7,})|((56[\s.-]*)?9[\s.-]*\d{4}[\s.-]*\d{4})', '[dato oculto]', 'g'),
             '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[dato oculto]', 'g'),
           '(https?://|www\.)\S+|\m(wa\.me|t\.me|bit\.ly)/\S*', '[dato oculto]', 'gi')
$$;

create table if not exists public.message_flags (
  id           bigint generated always as identity primary key,
  message_id   uuid references public.messages (id) on delete cascade,
  booking_id   uuid references public.bookings (id) on delete cascade,
  sender_id    uuid references public.profiles (id) on delete cascade,
  source       text not null default 'chat' check (source in ('chat', 'booking_request')),
  signals      text[] not null,
  masked       boolean not null default false,
  booking_status public.booking_status,
  status       text not null default 'open' check (status in ('open', 'reviewed', 'dismissed', 'actioned')),
  review_note  text,
  reviewed_by  uuid,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default clock_timestamp()
);

create index if not exists message_flags_open_idx on public.message_flags (status, created_at);

alter table public.message_flags enable row level security;
revoke all on public.message_flags from anon, authenticated;
grant select on public.message_flags to service_role;

alter table public.messages add column if not exists moderation jsonb;

-- Antes de confirmar la reserva se ocultan teléfonos, correos y links. Siempre se
-- marcan para revisión las señales de pago por fuera. Nunca se bloquea el mensaje.
create or replace function public.moderate_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  st public.booking_status := (select status from public.bookings where id = new.booking_id);
  sig text[] := public.contact_signals(new.body);
  pre boolean := st in ('solicitada', 'aceptada');
  masked boolean := false;
begin
  if pre and sig && array['phone', 'email', 'link'] then
    new.body := left(public.mask_contact_data(new.body), 2000);
    masked := true;
  end if;
  -- Después de confirmar, compartir un teléfono para coordinar la entrega es normal.
  if not pre then
    sig := array(select s from unnest(sig) s where s not in ('phone', 'email', 'link', 'messaging_app'));
  end if;
  -- Las partes solo ven si se ocultó un dato; las señales quedan para revisión (solo administración).
  if masked then
    new.moderation := jsonb_build_object('masked', true);
  end if;
  if cardinality(sig) > 0 then
    perform set_config('rue.msgmod_' || replace(new.id::text, '-', ''),
                       jsonb_build_object('signals', to_jsonb(sig), 'masked', masked, 'booking_status', st)::text, true);
  end if;
  return new;
end;
$$;

drop trigger if exists messages_moderate on public.messages;
create trigger messages_moderate
  before insert on public.messages
  for each row execute function public.moderate_message();

create or replace function public.flag_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb := nullif(current_setting('rue.msgmod_' || replace(new.id::text, '-', ''), true), '')::jsonb;
begin
  if m is not null then
    insert into public.message_flags (message_id, booking_id, sender_id, signals, masked, booking_status)
    select new.id, new.booking_id, new.sender_id, array(select jsonb_array_elements_text(m -> 'signals')),
           coalesce((m ->> 'masked')::boolean, false), (m ->> 'booking_status')::public.booking_status;
    perform public.emit_domain_event('off_platform_signal', new.booking_id, null,
      jsonb_build_object('source', 'chat', 'signals', m -> 'signals', 'masked', m -> 'masked'));
  end if;
  return null;
end;
$$;

drop trigger if exists messages_flag on public.messages;
create trigger messages_flag
  after insert on public.messages
  for each row execute function public.flag_message();

-- Publicaciones y perfiles: sin datos de contacto (el contacto es por el chat de RUÉ).
create or replace function public.forbid_contact_in_listing()
returns trigger
language plpgsql
as $$
begin
  if public.contact_signals(concat_ws(' ', new.title, new.description, new.pickup_location)) && array['phone', 'email', 'link'] then
    raise exception 'No incluyas teléfonos, correos ni links en la publicación: el contacto es por el chat de RUÉ.'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists vehicles_no_contact on public.vehicles;
create trigger vehicles_no_contact
  before insert or update of title, description, pickup_location on public.vehicles
  for each row execute function public.forbid_contact_in_listing();

create or replace function public.forbid_contact_in_profile()
returns trigger
language plpgsql
as $$
begin
  if public.contact_signals(concat_ws(' ', new.display_name, new.bio)) && array['phone', 'email', 'link'] then
    raise exception 'No incluyas teléfonos, correos ni links en tu perfil: el contacto es por el chat de RUÉ.'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_no_contact on public.profiles;
create trigger profiles_no_contact
  before update of display_name, bio on public.profiles
  for each row execute function public.forbid_contact_in_profile();

-- -----------------------------------------------------------------------------
-- 5. Solicitud con oferta y relación previa (reemplaza request_booking de 0008)
-- -----------------------------------------------------------------------------

drop function if exists public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean);

create function public.request_booking(
  p_vehicle_id uuid,
  p_start date,
  p_end date,
  p_purpose public.booking_purpose default null,
  p_message text default null,
  p_terms_version text default null,
  p_accept_terms boolean default false,
  p_accept_data_sharing boolean default false,
  p_offer_daily_clp int default null
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
  gd  record;
  offer int;
  new_id uuid;
  pair_done int;
  msg text;
  msg_signals text[];
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

  -- Oferta: igual o mayor al publicado = reserva normal al precio publicado.
  select * into gd from public.price_guidance(p_vehicle_id, p_start, p_end);
  if p_offer_daily_clp is not null and p_offer_daily_clp < gd.published_daily_clp then
    perform public.assert_valid_offer(p_vehicle_id, p_start, p_end, p_offer_daily_clp);
    offer := p_offer_daily_clp;
  end if;

  select * into p from public.price_booking(p_vehicle_id, p_start, p_end, offer);

  select count(*) into pair_done from public.bookings x
   where x.status = 'finalizada'
     and ((x.renter_id = uid and x.owner_id = v.owner_id) or (x.renter_id = v.owner_id and x.owner_id = uid));

  msg := nullif(btrim(left(p_message, 1000)), '');
  msg_signals := public.contact_signals(coalesce(msg, ''));
  if msg_signals && array['phone', 'email', 'link'] then
    msg := left(public.mask_contact_data(msg), 1000);
  end if;

  insert into public.bookings (
    vehicle_id, renter_id, owner_id, status, purpose, start_date, end_date, days,
    rental_clp, rental_extras_clp, gmv_clp, renter_fee_clp, owner_commission_clp, total_clp,
    owner_payout_clp, deposit_clp, platform_gross_revenue_clp,
    economic_config_id, guarantee_rule_id, pricing_snapshot,
    renter_message, expires_at
  ) values (
    v.id, uid, v.owner_id, 'solicitada', p_purpose, p_start, p_end, p.days,
    p.rental_clp, p.rental_extras_clp, p.gmv_clp, p.renter_fee_clp, p.owner_commission_clp, p.total_clp,
    p.owner_payout_clp, p.deposit_clp, p.platform_gross_revenue_clp,
    p.economic_config_id, p.guarantee_rule_id,
    p.pricing_snapshot || jsonb_build_object('relationship', jsonb_build_object('repeat_pair_completed', pair_done)),
    msg,
    now() + make_interval(hours => coalesce(public.setting_numeric('request_expiry_hours'), 24)::int)
  )
  returning id into new_id;

  insert into public.booking_consents (booking_id, user_id, terms_version, terms_accepted, data_sharing_accepted)
  values (new_id, uid, current_terms, true, true);

  if offer is not null then
    insert into public.booking_offers (booking_id, sender_id, recipient_id, amount_clp, round_number, max_rounds, offer_rule_id, expires_at)
    values (new_id, uid, v.owner_id, offer, 1, gd.max_rounds, gd.offer_rule_id,
            now() + make_interval(hours => least(gd.offer_ttl_hours, coalesce(public.setting_numeric('request_expiry_hours'), 24)::int)));
  end if;

  if cardinality(msg_signals) > 0 then
    insert into public.message_flags (booking_id, sender_id, source, signals, masked, booking_status)
    values (new_id, uid, 'booking_request', msg_signals, msg_signals && array['phone', 'email', 'link'], 'solicitada');
  end if;

  return new_id;
end;
$$;

-- Cotización con guía de precio y oferta opcional (reemplaza la de 0008).
drop function if exists public.quote_booking(uuid, date, date);

create function public.quote_booking(p_vehicle_id uuid, p_start date, p_end date, p_offer_daily_clp int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v  public.vehicles%rowtype;
  p  record;
  gd record;
  offer int;
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found or (v.status <> 'publicado' and v.owner_id is distinct from auth.uid()) then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;
  perform public.assert_bookable(v, p_start, p_end);
  select * into gd from public.price_guidance(p_vehicle_id, p_start, p_end);
  if p_offer_daily_clp is not null and p_offer_daily_clp < gd.published_daily_clp then
    perform public.assert_valid_offer(p_vehicle_id, p_start, p_end, p_offer_daily_clp);
    offer := p_offer_daily_clp;
  end if;
  select * into p from public.price_booking(p_vehicle_id, p_start, p_end, offer);

  return jsonb_build_object(
    'days', p.days,
    'rental_clp', p.rental_clp,
    'rental_extras_clp', p.rental_extras_clp,
    'renter_fee_clp', p.renter_fee_clp,
    'total_clp', p.total_clp,
    'deposit_clp', p.deposit_clp,
    'published_daily_clp', gd.published_daily_clp,
    'recommended_daily_low_clp', gd.recommended_low_clp,
    'recommended_daily_high_clp', gd.recommended_high_clp,
    'offer_daily_clp', offer,
    'max_rounds', gd.max_rounds
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Check-in / check-out
-- -----------------------------------------------------------------------------

alter table public.booking_handovers add column if not exists damages jsonb not null default '[]'::jsonb;
alter table public.booking_handovers add column if not exists latitude numeric(9,6) check (latitude between -90 and 90);
alter table public.booking_handovers add column if not exists longitude numeric(9,6) check (longitude between -180 and 180);
alter table public.booking_handovers add column if not exists captured_at timestamptz not null default now();
alter table public.booking_handovers add column if not exists owner_confirmed_at timestamptz;
alter table public.booking_handovers add column if not exists renter_confirmed_at timestamptz;
-- Futuro (no MVP): damage_detection, photo_comparison, odometer_ocr.
alter table public.booking_handovers add column if not exists analysis jsonb not null default '{}'::jsonb;
alter table public.booking_handovers add column if not exists analysis_status text not null default 'not_requested'
  check (analysis_status in ('not_requested', 'pending', 'done', 'failed'));

-- Actas anteriores: las confirma quien las hizo.
update public.booking_handovers h
   set owner_confirmed_at = case when h.author_id = b.owner_id then h.created_at else h.owner_confirmed_at end,
       renter_confirmed_at = case when h.author_id = b.renter_id then h.created_at else h.renter_confirmed_at end
  from public.bookings b
 where b.id = h.booking_id and h.owner_confirmed_at is null and h.renter_confirmed_at is null;

create or replace function public.valid_damages(p jsonb)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) <= 30
     and not exists (
       select 1 from jsonb_array_elements(p) d
       where jsonb_typeof(d) <> 'object'
          or coalesce(char_length(d ->> 'zone'), 0) not between 1 and 60
          or char_length(coalesce(d ->> 'description', '')) > 300
          or exists (select 1 from jsonb_object_keys(d) k where k not in ('zone', 'description', 'photo_path'))
     )
$$;

alter table public.booking_handovers drop constraint if exists booking_handovers_damages_valid;
alter table public.booking_handovers add constraint booking_handovers_damages_valid check (public.valid_damages(damages));

drop function if exists public.submit_handover(uuid, text, int, int, text, text[]);

create function public.submit_handover(
  p_booking_id uuid, p_kind text, p_odometer_km int, p_fuel_level int, p_notes text, p_photo_paths text[],
  p_damages jsonb default '[]'::jsonb, p_latitude numeric default null, p_longitude numeric default null
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
  other uuid;
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
  if exists (select 1 from unnest(coalesce(p_photo_paths, '{}')) ph where split_part(ph, '/', 1) <> b.id::text)
     or exists (select 1 from jsonb_array_elements(coalesce(p_damages, '[]'::jsonb)) d
                where d ? 'photo_path' and split_part(d ->> 'photo_path', '/', 1) <> b.id::text) then
    raise exception 'Fotos no válidas' using errcode = '22023';
  end if;
  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'Ubicación incompleta' using errcode = '22023';
  end if;

  insert into public.booking_handovers (booking_id, kind, author_id, odometer_km, fuel_level, notes, photo_paths,
                                        damages, latitude, longitude, owner_confirmed_at, renter_confirmed_at)
  values (b.id, p_kind, uid, p_odometer_km, p_fuel_level, nullif(btrim(p_notes), ''), coalesce(p_photo_paths, '{}'),
          coalesce(p_damages, '[]'::jsonb), p_latitude, p_longitude,
          case when uid = b.owner_id then now() end, case when uid = b.renter_id then now() end)
  returning id into new_id;

  other := case when uid = b.owner_id then b.renter_id else b.owner_id end;
  insert into public.notifications (user_id, kind, title, body, booking_id)
  values (other, 'handover_to_confirm',
          case when p_kind = 'entrega' then 'Confirma el acta de entrega' else 'Revisa el acta de devolución' end,
          'Revisa kilometraje, combustible, daños y fotos, y confírmala en la reserva.', b.id);
  return new_id;
end;
$$;

-- La otra parte confirma el acta (o deja su propia observación con otra acta).
create or replace function public.confirm_handover(p_handover_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  h public.booking_handovers%rowtype;
  b public.bookings%rowtype;
begin
  select * into h from public.booking_handovers where id = p_handover_id for update;
  if not found then
    raise exception 'Acta no encontrada' using errcode = 'P0002';
  end if;
  select * into b from public.bookings where id = h.booking_id;
  if uid is null or (b.owner_id <> uid and b.renter_id <> uid) then
    raise exception 'Acta no encontrada' using errcode = 'P0002';
  end if;
  if b.status not in ('confirmada', 'en_curso', 'devuelta') then
    raise exception 'Esta reserva ya no admite confirmar actas' using errcode = 'P0001';
  end if;
  update public.booking_handovers
     set owner_confirmed_at  = case when uid = b.owner_id  then coalesce(owner_confirmed_at, now())  else owner_confirmed_at end,
         renter_confirmed_at = case when uid = b.renter_id then coalesce(renter_confirmed_at, now()) else renter_confirmed_at end
   where id = h.id
  returning * into h;
  if h.owner_confirmed_at is not null and h.renter_confirmed_at is not null then
    perform public.emit_domain_event(case when h.kind = 'entrega' then 'check_in_completed' else 'check_out_completed' end,
                                     b.id, b.vehicle_id, jsonb_build_object('handover_id', h.id));
  end if;
end;
$$;

-- Antes / después para la reserva (solo participantes).
create or replace function public.handover_comparison(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
  hin public.booking_handovers%rowtype;
  hout public.booking_handovers%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or (b.owner_id is distinct from auth.uid() and b.renter_id is distinct from auth.uid() and not public.is_admin()) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  select * into hin from public.booking_handovers where booking_id = b.id and kind = 'entrega' order by created_at desc limit 1;
  select * into hout from public.booking_handovers where booking_id = b.id and kind = 'devolucion' order by created_at desc limit 1;
  return jsonb_build_object(
    'check_in',  case when hin.id is null then null else jsonb_build_object(
                   'id', hin.id, 'at', hin.captured_at, 'odometer_km', hin.odometer_km, 'fuel_level', hin.fuel_level,
                   'damages', hin.damages, 'photos', cardinality(hin.photo_paths),
                   'confirmed_by_both', hin.owner_confirmed_at is not null and hin.renter_confirmed_at is not null) end,
    'check_out', case when hout.id is null then null else jsonb_build_object(
                   'id', hout.id, 'at', hout.captured_at, 'odometer_km', hout.odometer_km, 'fuel_level', hout.fuel_level,
                   'damages', hout.damages, 'photos', cardinality(hout.photo_paths),
                   'confirmed_by_both', hout.owner_confirmed_at is not null and hout.renter_confirmed_at is not null) end,
    'km_driven', case when hin.odometer_km is not null and hout.odometer_km is not null then hout.odometer_km - hin.odometer_km end,
    'fuel_delta', case when hin.fuel_level is not null and hout.fuel_level is not null then hout.fuel_level - hin.fuel_level end,
    'new_damage_zones', case when hout.id is null then '[]'::jsonb else coalesce((
        select jsonb_agg(distinct d ->> 'zone') from jsonb_array_elements(hout.damages) d
        where not exists (select 1 from jsonb_array_elements(coalesce(hin.damages, '[]'::jsonb)) e
                          where lower(e ->> 'zone') = lower(d ->> 'zone'))), '[]'::jsonb) end,
    'km_allowed', case when (select km_per_day from public.vehicles where id = b.vehicle_id) is not null
                       then (select km_per_day from public.vehicles where id = b.vehicle_id) * (b.end_date - b.start_date) end
  );
end;
$$;

-- transition_booking: el check-in exige confirmación de ambas partes (reemplaza 0006).
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

  -- Aceptar se hace con accept_booking / accept_offer.
  ok := case role
    when 'owner' then (b.status, p_to) in (
      ('solicitada', 'rechazada'),
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

  if p_to = 'en_curso' then
    if public.today_cl() < b.start_date then
      raise exception 'La entrega se puede marcar desde el %', to_char(b.start_date, 'DD-MM-YYYY') using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.booking_handovers where booking_id = b.id and kind = 'entrega'
                   and owner_confirmed_at is not null and renter_confirmed_at is not null) then
      raise exception 'Primero completen y confirmen ambos el acta de entrega' using errcode = 'P0001';
    end if;
  end if;

  if p_to = 'devuelta' and not exists (select 1 from public.booking_handovers where booking_id = b.id
                                       and kind = 'devolucion' and owner_confirmed_at is not null) then
    raise exception 'Primero completa el acta de devolución (kilometraje, combustible y fotos)' using errcode = 'P0001';
  end if;

  perform set_config('rue.transition_note', coalesce(left(p_note, 500), ''), true);
  update public.bookings
     set status = p_to,
         cancelled_by = case when p_to = 'cancelada' then uid else cancelled_by end,
         expires_at = null
   where id = b.id
   returning * into b;
  perform set_config('rue.transition_note', '', true);
  return b;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Extensiones
-- -----------------------------------------------------------------------------

create table if not exists public.booking_extensions (
  id                          uuid primary key default gen_random_uuid(),
  booking_id                  uuid not null references public.bookings (id) on delete restrict,
  requested_by                uuid not null references public.profiles (id),
  old_end_date                date not null,
  new_end_date                date not null,
  days                        int not null check (days > 0),
  daily_rate_clp              int not null check (daily_rate_clp > 0),
  rental_clp                  int not null check (rental_clp >= 0),
  gmv_clp                     int not null check (gmv_clp >= 0),
  renter_fee_clp              int not null check (renter_fee_clp >= 0),
  owner_commission_clp        int not null check (owner_commission_clp >= 0),
  total_clp                   int not null check (total_clp >= 0),
  owner_payout_clp            int not null check (owner_payout_clp >= 0),
  platform_gross_revenue_clp  int not null check (platform_gross_revenue_clp >= 0),
  economic_config_id          bigint not null references public.economic_config_versions (id),
  pricing_snapshot            jsonb not null,
  status                      text not null default 'pending_owner'
                              check (status in ('pending_owner', 'awaiting_payment', 'paid', 'rejected', 'expired', 'cancelled')),
  expires_at                  timestamptz,
  approved_at                 timestamptz,
  paid_at                     timestamptz,
  created_at                  timestamptz not null default clock_timestamp(),
  updated_at                  timestamptz not null default clock_timestamp(),
  constraint booking_extensions_range check (new_end_date > old_end_date)
);

create unique index if not exists booking_extensions_one_open on public.booking_extensions (booking_id)
  where status in ('pending_owner', 'awaiting_payment');

alter table public.booking_extensions enable row level security;

create policy "booking_extensions: participantes leen"
  on public.booking_extensions for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())));

revoke all on public.booking_extensions from anon;
revoke insert, update, delete on public.booking_extensions from authenticated;
grant select on public.booking_extensions to authenticated;

-- Montos y snapshot de la extensión son inmutables.
create or replace function public.freeze_extension()
returns trigger
language plpgsql
as $$
begin
  if (new.booking_id, new.old_end_date, new.new_end_date, new.days, new.daily_rate_clp, new.rental_clp, new.gmv_clp,
      new.renter_fee_clp, new.owner_commission_clp, new.total_clp, new.owner_payout_clp,
      new.platform_gross_revenue_clp, new.economic_config_id, new.pricing_snapshot)
     is distinct from
     (old.booking_id, old.old_end_date, old.new_end_date, old.days, old.daily_rate_clp, old.rental_clp, old.gmv_clp,
      old.renter_fee_clp, old.owner_commission_clp, old.total_clp, old.owner_payout_clp,
      old.platform_gross_revenue_clp, old.economic_config_id, old.pricing_snapshot) then
    raise exception 'Los datos económicos de una extensión no se pueden modificar' using errcode = 'P0001';
  end if;
  if old.status in ('paid', 'rejected', 'expired', 'cancelled') and new.status is distinct from old.status then
    raise exception 'La extensión ya está cerrada' using errcode = 'P0001';
  end if;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists booking_extensions_freeze on public.booking_extensions;
create trigger booking_extensions_freeze
  before update on public.booking_extensions
  for each row execute function public.freeze_extension();

alter table public.payments add column if not exists extension_id uuid references public.booking_extensions (id);
create index if not exists payments_extension_idx on public.payments (extension_id) where extension_id is not null;

create or replace function public.request_extension(p_booking_id uuid, p_new_end date)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  b    public.bookings%rowtype;
  v    public.vehicles%rowtype;
  cfg  public.economic_config_versions%rowtype;
  n    int;
  rate int;
  rental int;
  fee int;
  com int;
  new_id uuid;
  max_days int := coalesce(public.setting_numeric('max_booking_days'), 90)::int;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.renter_id is distinct from uid then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  if b.status not in ('confirmada', 'en_curso') then
    raise exception 'Solo puedes extender una reserva pagada que no ha terminado' using errcode = 'P0001';
  end if;
  if p_new_end is null or p_new_end <= b.end_date then
    raise exception 'La nueva fecha de devolución debe ser posterior a la actual' using errcode = '22023';
  end if;
  if p_new_end - b.start_date > max_days then
    raise exception 'Una reserva puede durar máximo % días', max_days using errcode = '22023';
  end if;
  if exists (select 1 from public.booking_extensions where booking_id = b.id and status in ('pending_owner', 'awaiting_payment')) then
    raise exception 'Ya tienes una extensión en curso para esta reserva' using errcode = 'P0001';
  end if;
  if not public.vehicle_is_available(b.vehicle_id, b.end_date, p_new_end, b.id) then
    raise exception 'El vehículo no está disponible para esas fechas' using errcode = 'P0001';
  end if;
  perform public.assert_can_rent();

  select * into v from public.vehicles where id = b.vehicle_id;
  cfg := public.active_economic_config();
  if cfg.tax_treatment <> 'pending_accountant' then
    raise exception 'Tratamiento tributario % aún no implementado', cfg.tax_treatment using errcode = 'P0001';
  end if;
  n := p_new_end - b.end_date;
  -- Se mantiene la tarifa diaria del contrato (acordada o publicada).
  rate := coalesce((b.pricing_snapshot #>> '{negotiation,agreed_daily_clp}')::int, round(b.rental_clp::numeric / b.days)::int);
  rental := n * rate;
  fee := round(rental * cfg.renter_service_fee_rate)::int;
  com := round(rental * cfg.owner_fee_rate)::int;

  insert into public.booking_extensions (
    booking_id, requested_by, old_end_date, new_end_date, days, daily_rate_clp, rental_clp, gmv_clp,
    renter_fee_clp, owner_commission_clp, total_clp, owner_payout_clp, platform_gross_revenue_clp,
    economic_config_id, pricing_snapshot, expires_at
  ) values (
    b.id, uid, b.end_date, p_new_end, n, rate, rental, rental, fee, com, rental + fee, rental - com, fee + com,
    cfg.id,
    jsonb_build_object(
      'pricing_version', 'rue-extension-1', 'computed_at', clock_timestamp(),
      'inputs', jsonb_build_object('booking_id', b.id, 'old_end_date', b.end_date, 'new_end_date', p_new_end,
                                   'days', n, 'daily_rate_clp', rate, 'rate_source',
                                   case when b.pricing_snapshot #>> '{negotiation,agreed_daily_clp}' is not null then 'agreed' else 'contract_average' end),
      'economic_config', jsonb_build_object('id', cfg.id, 'version', cfg.version, 'owner_fee_rate', cfg.owner_fee_rate,
                                            'renter_service_fee_rate', cfg.renter_service_fee_rate, 'tax_treatment', cfg.tax_treatment),
      'outputs', jsonb_build_object('rental_clp', rental, 'gmv_clp', rental, 'owner_fee_clp', com,
                                    'renter_service_fee_clp', fee, 'charged_clp', rental + fee,
                                    'owner_payout_clp', rental - com, 'platform_gross_revenue_clp', fee + com, 'tax_clp', null)
    ),
    now() + make_interval(hours => coalesce(public.setting_numeric('request_expiry_hours'), 24)::int)
  )
  returning id into new_id;

  insert into public.notifications (user_id, kind, title, body, booking_id)
  values (b.owner_id, 'extension_requested', 'Piden extender el arriendo',
          'Hasta el ' || to_char(p_new_end, 'DD-MM-YYYY') || ' (' || n || ' días más). Apruébala o recházala.', b.id);
  return new_id;
end;
$$;

create or replace function public.respond_extension(p_extension_id uuid, p_approve boolean)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  e public.booking_extensions%rowtype;
  b public.bookings%rowtype;
begin
  select * into e from public.booking_extensions where id = p_extension_id for update;
  if not found then
    raise exception 'Extensión no encontrada' using errcode = 'P0002';
  end if;
  select * into b from public.bookings where id = e.booking_id;
  if b.owner_id is distinct from auth.uid() then
    raise exception 'Extensión no encontrada' using errcode = 'P0002';
  end if;
  if e.status <> 'pending_owner' or (e.expires_at is not null and e.expires_at < now()) then
    raise exception 'Esta solicitud ya no se puede responder' using errcode = 'P0001';
  end if;
  if p_approve then
    if not public.vehicle_is_available(b.vehicle_id, e.old_end_date, e.new_end_date, b.id) then
      raise exception 'El vehículo ya no está disponible para esas fechas' using errcode = 'P0001';
    end if;
    update public.booking_extensions
       set status = 'awaiting_payment', approved_at = now(),
           expires_at = now() + make_interval(hours => coalesce(public.setting_numeric('payment_expiry_hours'), 24)::int)
     where id = e.id;
    insert into public.notifications (user_id, kind, title, body, booking_id)
    values (b.renter_id, 'extension_approved', 'Extensión aprobada', 'Paga la extensión para confirmarla.', b.id);
  else
    update public.booking_extensions set status = 'rejected' where id = e.id;
    insert into public.notifications (user_id, kind, title, body, booking_id)
    values (b.renter_id, 'extension_rejected', 'Extensión no aprobada', 'Devuelve el vehículo en la fecha acordada.', b.id);
  end if;
end;
$$;

create or replace function public.cancel_extension(p_extension_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  update public.booking_extensions e
     set status = 'cancelled'
   where e.id = p_extension_id and e.status in ('pending_owner', 'awaiting_payment')
     and exists (select 1 from public.bookings b where b.id = e.booking_id and b.renter_id = auth.uid());
  if not found then
    raise exception 'Esta extensión ya no se puede cancelar' using errcode = 'P0001';
  end if;
end;
$$;

-- Solo servidor (webpay-return). Idempotente, mismos resultados que confirm_booking_payment.
create or replace function public.confirm_extension_payment(
  p_extension_id uuid, p_provider_payment_id text, p_amount_clp int, p_environment text, p_provider text default 'webpay'
)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  e public.booking_extensions%rowtype;
  b public.bookings%rowtype;
begin
  select * into e from public.booking_extensions where id = p_extension_id for update;
  if not found then
    raise exception 'Extensión no encontrada' using errcode = 'P0002';
  end if;
  select * into b from public.bookings where id = e.booking_id for update;

  insert into public.payments (booking_id, extension_id, provider, environment, provider_payment_id, status, amount_clp)
  values (b.id, e.id, p_provider, p_environment, p_provider_payment_id, 'approved', p_amount_clp)
  on conflict (provider, provider_payment_id)
  do update set status = 'approved', extension_id = coalesce(public.payments.extension_id, excluded.extension_id);

  if e.status = 'paid' then
    return 'already_confirmed';
  end if;
  if p_amount_clp <> e.total_clp then
    return 'amount_mismatch';
  end if;
  if e.status <> 'awaiting_payment' or (e.expires_at is not null and e.expires_at < now())
     or b.status not in ('confirmada', 'en_curso') or b.end_date <> e.old_end_date
     or not public.vehicle_is_available(b.vehicle_id, e.old_end_date, e.new_end_date, b.id) then
    return 'not_payable';
  end if;

  begin
    perform set_config('rue.extension', 'on', true);
    perform set_config('rue.transition_note', 'Extensión pagada hasta ' || to_char(e.new_end_date, 'DD-MM-YYYY'), true);
    update public.bookings set end_date = e.new_end_date where id = b.id;
    perform set_config('rue.extension', '', true);
  exception when exclusion_violation then
    perform set_config('rue.extension', '', true);
    return 'not_payable';
  end;

  insert into public.booking_events (booking_id, from_status, to_status, actor_id, note)
  values (b.id, b.status, b.status, null, 'Extensión pagada: nueva devolución ' || to_char(e.new_end_date, 'DD-MM-YYYY'));
  update public.booking_extensions set status = 'paid', paid_at = now(), expires_at = null where id = e.id;
  insert into public.notifications (user_id, kind, title, body, booking_id) values
    (b.renter_id, 'extension_paid', 'Extensión confirmada', 'Nueva devolución: ' || to_char(e.new_end_date, 'DD-MM-YYYY') || '.', b.id),
    (b.owner_id,  'extension_paid', 'Extensión pagada', 'La reserva se extendió hasta el ' || to_char(e.new_end_date, 'DD-MM-YYYY') || '.', b.id);
  return 'confirmed';
end;
$$;

-- Extensiones abiertas se cierran si la reserva termina o se cancela.
create or replace function public.close_extensions_on_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status and new.status in ('devuelta', 'finalizada', 'cancelada', 'disputada') then
    update public.booking_extensions set status = 'cancelled'
     where booking_id = new.id and status in ('pending_owner', 'awaiting_payment');
  end if;
  return null;
end;
$$;

drop trigger if exists bookings_close_extensions on public.bookings;
create trigger bookings_close_extensions
  after update of status on public.bookings
  for each row execute function public.close_extensions_on_booking_change();

-- Vencimientos (reemplaza la de 0002): también extensiones sin respuesta o sin pago.
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
  update public.booking_extensions set status = 'expired'
   where status in ('pending_owner', 'awaiting_payment') and expires_at is not null and expires_at < now();
  return n;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Ledger y payouts con extensiones
-- -----------------------------------------------------------------------------

alter table public.ledger_entries drop constraint if exists ledger_entries_entry_type_check;
alter table public.ledger_entries add constraint ledger_entries_entry_type_check check (entry_type in (
  'payment_received', 'refund', 'payment_processing_cost',
  'rental_base', 'rental_extra',
  'owner_fee', 'renter_service_fee', 'other_platform_revenue',
  'owner_payout_due', 'owner_payout_paid',
  'guarantee_hold', 'guarantee_release', 'guarantee_capture',
  'protection_fee', 'tax'));
alter table public.ledger_entries add column if not exists extension_id uuid references public.booking_extensions (id);

drop function if exists public.ledger_post(text, text, int, uuid, uuid, uuid, text);

create function public.ledger_post(
  p_key text, p_entry_type text, p_amount int,
  p_booking_id uuid default null, p_payment_id uuid default null, p_payout_id uuid default null,
  p_memo text default null, p_extension_id uuid default null, p_config_id bigint default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  cfg_id bigint := p_config_id;
begin
  if p_amount is null or p_amount = 0 then
    return;
  end if;
  if cfg_id is null and p_booking_id is not null then
    select economic_config_id into cfg_id from public.bookings where id = p_booking_id;
  end if;
  insert into public.ledger_entries (
    booking_id, payment_id, payout_id, extension_id, entry_type, gross_amount_clp, tax_status,
    counts_as_gmv, counts_as_revenue, economic_config_id, idempotency_key, memo, created_by
  ) values (
    p_booking_id, p_payment_id, p_payout_id, p_extension_id, p_entry_type, p_amount,
    case when p_entry_type in ('owner_fee', 'renter_service_fee', 'other_platform_revenue', 'rental_base', 'rental_extra', 'payment_received', 'refund')
         then 'pending_accountant' else 'not_applicable' end,
    p_entry_type in ('rental_base', 'rental_extra'),
    p_entry_type in ('owner_fee', 'renter_service_fee', 'other_platform_revenue'),
    cfg_id, p_key, p_memo, auth.uid()
  )
  on conflict (idempotency_key) do nothing;
end;
$$;

create or replace function public.ledger_on_extension_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  k text := 'extension:' || new.id || ':';
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    perform public.ledger_post(k || 'rental_base',        'rental_base',        new.rental_clp,           new.booking_id, null, null, 'Extensión', new.id, new.economic_config_id);
    perform public.ledger_post(k || 'owner_fee',          'owner_fee',          new.owner_commission_clp, new.booking_id, null, null, 'Extensión', new.id, new.economic_config_id);
    perform public.ledger_post(k || 'renter_service_fee', 'renter_service_fee', new.renter_fee_clp,       new.booking_id, null, null, 'Extensión', new.id, new.economic_config_id);
    perform public.ledger_post(k || 'owner_payout_due',   'owner_payout_due',   new.owner_payout_clp,     new.booking_id, null, null, 'Extensión', new.id, new.economic_config_id);
  end if;
  return null;
end;
$$;

drop trigger if exists booking_extensions_ledger on public.booking_extensions;
create trigger booking_extensions_ledger
  after update of status on public.booking_extensions
  for each row execute function public.ledger_on_extension_paid();

-- Cancelación después del pago: también revierte extensiones pagadas (reemplaza 0008).
create or replace function public.ledger_on_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  k text := 'booking:' || new.id || ':';
  e record;
begin
  if new.status is not distinct from old.status then
    return null;
  end if;

  if new.status = 'confirmada' then
    perform public.ledger_post(k || 'rental_base',        'rental_base',        new.rental_clp,           new.id);
    perform public.ledger_post(k || 'rental_extra',       'rental_extra',       new.rental_extras_clp,    new.id);
    perform public.ledger_post(k || 'owner_fee',          'owner_fee',          new.owner_commission_clp, new.id);
    perform public.ledger_post(k || 'renter_service_fee', 'renter_service_fee', new.renter_fee_clp,       new.id);
    perform public.ledger_post(k || 'owner_payout_due',   'owner_payout_due',   new.owner_payout_clp,     new.id);
  elsif new.status = 'cancelada' and new.confirmed_at is not null then
    perform public.ledger_post(k || 'rental_base:reversal',        'rental_base',        -new.rental_clp,           new.id, null, null, 'Cancelada después del pago');
    perform public.ledger_post(k || 'rental_extra:reversal',       'rental_extra',       -new.rental_extras_clp,    new.id, null, null, 'Cancelada después del pago');
    perform public.ledger_post(k || 'owner_fee:reversal',          'owner_fee',          -new.owner_commission_clp, new.id, null, null, 'Cancelada después del pago');
    perform public.ledger_post(k || 'renter_service_fee:reversal', 'renter_service_fee', -new.renter_fee_clp,       new.id, null, null, 'Cancelada después del pago');
    perform public.ledger_post(k || 'owner_payout_due:reversal',   'owner_payout_due',   -new.owner_payout_clp,     new.id, null, null, 'Cancelada después del pago');
    for e in select * from public.booking_extensions where booking_id = new.id and status = 'paid' loop
      perform public.ledger_post('extension:' || e.id || ':rental_base:reversal',        'rental_base',        -e.rental_clp,           new.id, null, null, 'Cancelada después del pago', e.id, e.economic_config_id);
      perform public.ledger_post('extension:' || e.id || ':owner_fee:reversal',          'owner_fee',          -e.owner_commission_clp, new.id, null, null, 'Cancelada después del pago', e.id, e.economic_config_id);
      perform public.ledger_post('extension:' || e.id || ':renter_service_fee:reversal', 'renter_service_fee', -e.renter_fee_clp,       new.id, null, null, 'Cancelada después del pago', e.id, e.economic_config_id);
      perform public.ledger_post('extension:' || e.id || ':owner_payout_due:reversal',   'owner_payout_due',   -e.owner_payout_clp,     new.id, null, null, 'Cancelada después del pago', e.id, e.economic_config_id);
    end loop;
  end if;
  return null;
end;
$$;

-- Payout incluye las extensiones pagadas (reemplaza 0008).
create or replace function public.sync_payout_with_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  delay int := coalesce((new.pricing_snapshot #>> '{economic_config,payout_delay_business_days}')::int,
                        (public.active_economic_config()).payout_delay_business_days, 2);
  base_day date;
  ext_payout int := coalesce((select sum(owner_payout_clp) from public.booking_extensions
                              where booking_id = new.id and status = 'paid'), 0);
begin
  if new.status is not distinct from old.status or new.confirmed_at is null then
    return null;
  end if;

  if new.status in ('devuelta', 'finalizada') then
    base_day := (coalesce(case when new.status = 'devuelta' then new.returned_at end, now()) at time zone 'America/Santiago')::date;
    insert into public.payouts (booking_id, owner_id, amount_clp, status, eligible_on)
    values (new.id, new.owner_id, new.owner_payout_clp + ext_payout, 'pending', public.add_business_days(base_day, delay))
    on conflict (booking_id) do nothing;
  elsif new.status = 'disputada' then
    update public.payouts
       set status = 'held', hold_reason = 'open_dispute', status_note = 'Reserva en disputa', updated_at = now()
     where booking_id = new.id and status in ('pending', 'eligible', 'scheduled');
  elsif new.status = 'cancelada' then
    update public.payouts
       set status = 'held', hold_reason = coalesce(hold_reason, 'payment_issue'),
           status_note = 'Reserva cancelada: revisar reembolso antes de pagar', updated_at = now()
     where booking_id = new.id and status in ('pending', 'eligible', 'scheduled');
  end if;
  return null;
end;
$$;

-- Reporting: columnas de extensiones al final (la vista conserva las anteriores).
create or replace view public.booking_financials as
select
  b.id                                   as booking_id,
  b.status,
  b.created_at,
  b.confirmed_at,
  b.returned_at,
  b.pricing_snapshot #>> '{economic_config,version}'      as economic_config_version,
  b.pricing_snapshot #>> '{economic_config,tax_treatment}' as tax_treatment,
  b.rental_clp                           as rental_base_amount,
  b.rental_extras_clp                    as rental_extras,
  b.gmv_clp                              as gmv_amount,
  b.owner_commission_clp                 as owner_fee,
  b.renter_fee_clp                       as renter_service_fee,
  b.total_clp                            as charged_amount,
  b.deposit_clp                          as guarantee_amount,
  case when coalesce(b.pricing_snapshot #>> '{economic_config,tax_treatment}', 'pending_accountant') = 'pending_accountant'
       then null else coalesce(l.tax, 0) end                as tax_amount,
  l.processing_cost                      as payment_processing_cost,
  coalesce(l.refunds, 0)                 as refunds,
  b.owner_payout_clp                     as owner_payout,
  po.status                              as payout_status,
  po.eligible_on                         as payout_eligible_on,
  b.platform_gross_revenue_clp           as platform_gross_revenue,
  case when coalesce(b.pricing_snapshot #>> '{economic_config,tax_treatment}', 'pending_accountant') = 'pending_accountant'
            or l.processing_cost is null then null
       else b.platform_gross_revenue_clp + coalesce(x.revenue, 0) - l.processing_cost - coalesce(l.tax, 0) end as platform_net_revenue,
  coalesce(x.gmv, 0)                     as extension_gmv_amount,
  coalesce(x.charged, 0)                 as extension_charged_amount,
  coalesce(x.payout, 0)                  as extension_owner_payout,
  coalesce(x.revenue, 0)                 as extension_platform_gross_revenue,
  (b.pricing_snapshot #>> '{negotiation,agreed_daily_clp}')::int     as agreed_daily_price,
  (b.pricing_snapshot #>> '{negotiation,published_daily_clp}')::int  as published_daily_price,
  (b.pricing_snapshot #>> '{relationship,repeat_pair_completed}')::int as repeat_pair_completed
from public.bookings b
left join public.payouts po on po.booking_id = b.id
left join lateral (
  select
    -sum(e.gross_amount_clp) filter (where e.entry_type = 'refund')                  as refunds,
    -sum(e.gross_amount_clp) filter (where e.entry_type = 'payment_processing_cost') as processing_cost,
    sum(e.tax_amount_clp)    filter (where e.tax_status = 'determined')              as tax
  from public.ledger_entries e where e.booking_id = b.id
) l on true
left join lateral (
  select sum(gmv_clp) as gmv, sum(total_clp) as charged, sum(owner_payout_clp) as payout,
         sum(platform_gross_revenue_clp) as revenue
  from public.booking_extensions where booking_id = b.id and status = 'paid'
) x on true;

revoke all on public.booking_financials from anon, authenticated;
grant select on public.booking_financials to service_role;

-- -----------------------------------------------------------------------------
-- 9. Contrato digital (y anexos por extensión)
-- -----------------------------------------------------------------------------

create table if not exists public.booking_agreements (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid not null references public.bookings (id) on delete restrict,
  version            int not null,
  kind               text not null check (kind in ('contract', 'extension_addendum')),
  extension_id       uuid references public.booking_extensions (id),
  terms_version      text not null,
  content            jsonb not null,
  content_sha256     text not null,
  renter_accepted_at timestamptz not null,
  owner_accepted_at  timestamptz not null,
  created_at         timestamptz not null default clock_timestamp(),
  constraint booking_agreements_version_unique unique (booking_id, version)
);

alter table public.booking_agreements enable row level security;

create policy "booking_agreements: participantes leen"
  on public.booking_agreements for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())));

revoke all on public.booking_agreements from anon;
revoke insert, update, delete on public.booking_agreements from authenticated;
grant select on public.booking_agreements to authenticated;

drop trigger if exists booking_agreements_immutable on public.booking_agreements;
create trigger booking_agreements_immutable
  before update or delete on public.booking_agreements
  for each row execute function public.forbid_update_delete();

create or replace function public.create_booking_agreement(p_booking_id uuid, p_extension_id uuid default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  b public.bookings%rowtype;
  v public.vehicles%rowtype;
  e public.booking_extensions%rowtype;
  c public.booking_consents%rowtype;
  ro public.profiles%rowtype;
  rr public.profiles%rowtype;
  doc jsonb;
  ver int;
  new_id uuid;
begin
  select * into b from public.bookings where id = p_booking_id;
  select * into v from public.vehicles where id = b.vehicle_id;
  select * into ro from public.profiles where id = b.owner_id;
  select * into rr from public.profiles where id = b.renter_id;
  select * into c from public.booking_consents where booking_id = b.id order by created_at desc limit 1;
  if p_extension_id is not null then
    select * into e from public.booking_extensions where id = p_extension_id;
  end if;
  select coalesce(max(version), 0) + 1 into ver from public.booking_agreements where booking_id = b.id;

  doc := jsonb_build_object(
    'kind', case when p_extension_id is null then 'contract' else 'extension_addendum' end,
    'booking_id', b.id,
    'terms_version', coalesce(c.terms_version, 'desconocida'),
    'parties', jsonb_build_object(
      'owner',  jsonb_build_object('user_id', ro.id, 'display_name', ro.display_name, 'identity_verified', ro.identity_verified),
      'renter', jsonb_build_object('user_id', rr.id, 'display_name', rr.display_name, 'identity_verified', rr.identity_verified,
                                   'license_verified', rr.license_verified),
      'legal_identity_note', 'RUÉ resguarda nombre completo y RUT de ambas partes; se comunican según cláusulas 16 a 19.'
    ),
    'vehicle', jsonb_build_object('id', v.id, 'type', v.vehicle_type, 'brand', v.brand, 'model', v.model, 'year', v.year,
                                  'plate', v.plate, 'km_per_day', v.km_per_day, 'fuel_policy', v.fuel_policy,
                                  'pickup_location', v.pickup_location, 'insurance_info', v.insurance_info),
    'period', jsonb_build_object('start_date', b.start_date,
                                 'end_date', case when p_extension_id is null then b.end_date else e.old_end_date end,
                                 'pickup_time', b.pickup_time, 'return_time', b.return_time, 'days', b.days),
    'economics', case when p_extension_id is null then jsonb_build_object(
                   'rental_clp', b.rental_clp, 'renter_service_fee_clp', b.renter_fee_clp, 'charged_clp', b.total_clp,
                   'owner_fee_clp', b.owner_commission_clp, 'owner_payout_clp', b.owner_payout_clp,
                   'guarantee_clp', b.deposit_clp, 'agreed_daily_clp', b.pricing_snapshot #> '{negotiation,agreed_daily_clp}',
                   'economic_config_version', b.pricing_snapshot #> '{economic_config,version}', 'tax', 'pendiente de definición')
                 else jsonb_build_object(
                   'new_end_date', e.new_end_date, 'days', e.days, 'daily_rate_clp', e.daily_rate_clp,
                   'rental_clp', e.rental_clp, 'renter_service_fee_clp', e.renter_fee_clp, 'charged_clp', e.total_clp,
                   'owner_fee_clp', e.owner_commission_clp, 'owner_payout_clp', e.owner_payout_clp) end,
    'consents', jsonb_build_object('terms_accepted', c.terms_accepted, 'data_sharing_accepted', c.data_sharing_accepted,
                                   'accepted_at', c.created_at),
    'protection', jsonb_build_object('status', 'not_offered',
                                     'note', 'RUÉ no ofrece todavía un producto de protección. Seguro declarado por el arrendador: ' || coalesce(v.insurance_info, 'no informado'))
  );

  insert into public.booking_agreements (booking_id, version, kind, extension_id, terms_version, content, content_sha256,
                                         renter_accepted_at, owner_accepted_at)
  values (b.id, ver, case when p_extension_id is null then 'contract' else 'extension_addendum' end, p_extension_id,
          coalesce(c.terms_version, 'desconocida'), doc, encode(sha256(convert_to(doc::text, 'UTF8')), 'hex'),
          case when p_extension_id is null then coalesce(c.created_at, b.created_at) else e.created_at end,
          case when p_extension_id is null then coalesce(b.accepted_at, now()) else coalesce(e.approved_at, now()) end)
  returning id into new_id;

  perform public.emit_domain_event('agreement_generated', b.id, b.vehicle_id,
    jsonb_build_object('version', ver, 'kind', case when p_extension_id is null then 'contract' else 'extension_addendum' end));
  return new_id;
end;
$$;

create or replace function public.agreement_on_booking_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'confirmada' and old.status is distinct from 'confirmada'
     and not exists (select 1 from public.booking_agreements where booking_id = new.id and kind = 'contract') then
    perform public.create_booking_agreement(new.id, null);
  end if;
  return null;
end;
$$;

drop trigger if exists bookings_agreement on public.bookings;
create trigger bookings_agreement
  after update of status on public.bookings
  for each row execute function public.agreement_on_booking_confirmed();

create or replace function public.agreement_on_extension_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    perform public.create_booking_agreement(new.booking_id, new.id);
  end if;
  return null;
end;
$$;

drop trigger if exists booking_extensions_agreement on public.booking_extensions;
create trigger booking_extensions_agreement
  after update of status on public.booking_extensions
  for each row execute function public.agreement_on_extension_paid();

-- -----------------------------------------------------------------------------
-- 10. Trust layer (datos públicos agregados, nunca privados)
-- -----------------------------------------------------------------------------

create or replace function public.user_trust(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'identity_verified', p.identity_verified,
    'license_verified', p.license_verified,
    'member_since', p.created_at,
    'completed_as_owner', (select count(*) from public.bookings where owner_id = p.id and status = 'finalizada'),
    'completed_as_renter', (select count(*) from public.bookings where renter_id = p.id and status = 'finalizada'),
    'rating_avg', (select round(avg(rating)::numeric, 1) from public.reviews where target_user_id = p.id),
    'rating_count', (select count(*) from public.reviews where target_user_id = p.id),
    'cancellations_12m', (select count(*) from public.bookings
                          where cancelled_by = p.id and status = 'cancelada' and accepted_at is not null
                            and cancelled_at > now() - interval '12 months'),
    -- Mediana de horas en responder solicitudes (como propietario, últimos 90 días)
    'response_time_hours', (select round((percentile_cont(0.5) within group (
                                order by extract(epoch from (coalesce(o.responded_at, ev.created_at) - b.created_at)) / 3600))::numeric, 1)
                            from public.bookings b
                            left join lateral (select min(created_at) as created_at from public.booking_events e
                                               where e.booking_id = b.id and e.to_status in ('aceptada', 'rechazada')) ev on true
                            left join lateral (select min(responded_at) as responded_at from public.booking_offers x
                                               where x.booking_id = b.id and x.recipient_id = p.id and x.responded_at is not null) o on true
                            where b.owner_id = p.id and b.created_at > now() - interval '90 days'
                              and coalesce(o.responded_at, ev.created_at) is not null),
    'response_rate', (select round(avg(case when b.status = 'vencida' and b.accepted_at is null then 0 else 1 end)::numeric, 2)
                      from public.bookings b
                      where b.owner_id = p.id and b.created_at > now() - interval '90 days'
                        and b.status not in ('solicitada'))
  )
  from public.profiles p where p.id = p_user_id
$$;

create or replace function public.vehicle_trust(p_vehicle_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.vehicles%rowtype;
  pub jsonb;
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found or (v.status <> 'publicado' and v.owner_id is distinct from auth.uid() and not public.is_admin()) then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;
  pub := jsonb_build_object(
    'verified', v.verified and coalesce(v.verified_until >= public.today_cl(), false),
    'completed_rentals', (select count(*) from public.bookings where vehicle_id = v.id and status = 'finalizada'),
    'rating_avg', (select round(avg(r.rating)::numeric, 1) from public.reviews r where r.vehicle_id = v.id and r.target_user_id = v.owner_id),
    'rating_count', (select count(*) from public.reviews r where r.vehicle_id = v.id and r.target_user_id = v.owner_id)
  );
  -- Solo para el propietario: utilización e incidentes.
  if v.owner_id = auth.uid() or public.is_admin() then
    pub := pub || jsonb_build_object(
      'booked_days_90d', (select coalesce(sum(least(b.end_date, public.today_cl()) - greatest(b.start_date, public.today_cl() - 90)), 0)
                          from public.bookings b
                          where b.vehicle_id = v.id and b.status in ('confirmada', 'en_curso', 'devuelta', 'finalizada', 'disputada')
                            and b.end_date > public.today_cl() - 90 and b.start_date < public.today_cl()),
      'disputes', (select count(*) from public.bookings where vehicle_id = v.id and (status = 'disputada'
                     or exists (select 1 from public.booking_events e where e.booking_id = bookings.id and e.to_status = 'disputada'))),
      'next_booking_start', (select min(start_date) from public.bookings where vehicle_id = v.id
                             and status in ('aceptada', 'confirmada') and start_date >= public.today_cl())
    );
    pub := pub || jsonb_build_object('utilization_90d', round((pub ->> 'booked_days_90d')::numeric / 90, 2));
  end if;
  return pub;
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. Eventos de dominio nuevos
-- -----------------------------------------------------------------------------

alter table public.domain_events drop constraint if exists domain_events_event_type_check;
alter table public.domain_events add constraint domain_events_event_type_check check (event_type in (
  'user_created', 'vehicle_created', 'vehicle_published', 'vehicle_unpublished',
  'search_performed', 'vehicle_viewed', 'booking_requested', 'booking_accepted',
  'booking_rejected', 'booking_expired', 'checkout_started', 'payment_approved',
  'payment_rejected', 'payment_refunded', 'booking_confirmed', 'booking_started',
  'vehicle_returned', 'booking_completed', 'booking_cancelled', 'dispute_opened',
  'dispute_closed', 'payout_eligible', 'payout_held', 'payout_paid',
  'offer_made', 'offer_countered', 'offer_accepted', 'offer_closed',
  'extension_requested', 'extension_approved', 'extension_rejected', 'extension_paid', 'extension_closed',
  'check_in_completed', 'check_out_completed', 'agreement_generated', 'off_platform_signal'));

create or replace function public.domain_events_on_offer()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  pl jsonb := jsonb_build_object('offer_id', new.id, 'round', new.round_number, 'amount_clp', new.amount_clp,
                                 'by', case when new.sender_id = (select owner_id from public.bookings where id = new.booking_id)
                                            then 'owner' else 'renter' end);
begin
  if tg_op = 'INSERT' then
    perform public.emit_domain_event(case when new.round_number = 1 then 'offer_made' else 'offer_countered' end, new.booking_id, null, pl);
  elsif new.status is distinct from old.status and new.status in ('accepted', 'rejected', 'expired', 'cancelled') then
    perform public.emit_domain_event(case when new.status = 'accepted' then 'offer_accepted' else 'offer_closed' end,
                                     new.booking_id, null, pl || jsonb_build_object('status', new.status));
  end if;
  return null;
end;
$$;

drop trigger if exists booking_offers_domain_events on public.booking_offers;
create trigger booking_offers_domain_events
  after insert or update of status on public.booking_offers
  for each row execute function public.domain_events_on_offer();

create or replace function public.domain_events_on_extension()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  pl jsonb := jsonb_build_object('extension_id', new.id, 'days', new.days, 'gmv_clp', new.gmv_clp,
                                 'platform_gross_revenue_clp', new.platform_gross_revenue_clp);
begin
  if tg_op = 'INSERT' then
    perform public.emit_domain_event('extension_requested', new.booking_id, null, pl);
  elsif new.status is distinct from old.status then
    perform public.emit_domain_event(case new.status
      when 'awaiting_payment' then 'extension_approved'
      when 'rejected' then 'extension_rejected'
      when 'paid' then 'extension_paid'
      else 'extension_closed' end, new.booking_id, null, pl || jsonb_build_object('status', new.status));
  end if;
  return null;
end;
$$;

drop trigger if exists booking_extensions_domain_events on public.booking_extensions;
create trigger booking_extensions_domain_events
  after insert or update of status on public.booking_extensions
  for each row execute function public.domain_events_on_extension();

-- Reserva: agrega negociación y relación previa al payload (reemplaza 0008).
create or replace function public.domain_events_on_booking()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ev text;
  v  record;
  pl jsonb;
begin
  select vehicle_type, city, comuna into v from public.vehicles where id = new.vehicle_id;
  pl := jsonb_build_object(
    'vehicle_type', v.vehicle_type, 'city', v.city, 'comuna', v.comuna,
    'days', new.days, 'purpose', new.purpose, 'gmv_clp', new.gmv_clp,
    'platform_gross_revenue_clp', new.platform_gross_revenue_clp,
    'lead_days', new.start_date - (new.created_at at time zone 'America/Santiago')::date,
    'negotiated', new.pricing_snapshot #>> '{negotiation,agreed_daily_clp}' is not null,
    'repeat_pair_completed', coalesce((new.pricing_snapshot #>> '{relationship,repeat_pair_completed}')::int, 0)
  );
  if tg_op = 'INSERT' then
    perform public.emit_domain_event('booking_requested', new.id, new.vehicle_id, pl);
    return null;
  end if;
  if new.status is not distinct from old.status then
    return null;
  end if;
  ev := case new.status
    when 'aceptada'   then 'booking_accepted'
    when 'rechazada'  then 'booking_rejected'
    when 'vencida'    then 'booking_expired'
    when 'confirmada' then 'booking_confirmed'
    when 'en_curso'   then 'booking_started'
    when 'devuelta'   then 'vehicle_returned'
    when 'finalizada' then 'booking_completed'
    when 'cancelada'  then 'booking_cancelled'
    when 'disputada'  then 'dispute_opened'
  end;
  pl := pl || jsonb_build_object('from', old.status);
  if ev is not null then
    perform public.emit_domain_event(ev, new.id, new.vehicle_id, pl);
  end if;
  if old.status = 'disputada' then
    perform public.emit_domain_event('dispute_closed', new.id, new.vehicle_id, pl || jsonb_build_object('resolution', new.status));
  end if;
  return null;
end;
$$;

-- -----------------------------------------------------------------------------
-- 12. Permisos
-- -----------------------------------------------------------------------------

revoke execute on function public.resolve_offer_rule(public.vehicle_type, jsonb) from public, anon, authenticated;
revoke execute on function public.publish_offer_rule(public.vehicle_type, numeric, numeric, numeric, int, int, text, text) from public, anon;
revoke execute on function public.round_to(numeric, int) from public, anon;
revoke execute on function public.price_booking(uuid, date, date, int) from public, anon, authenticated;
revoke execute on function public.compute_booking_price(uuid, date, date) from public, anon, authenticated;
revoke execute on function public.price_guidance(uuid, date, date) from public, anon, authenticated;
revoke execute on function public.assert_valid_offer(uuid, date, date, int) from public, anon, authenticated;
revoke execute on function public.reprice_booking(uuid, int, uuid) from public, anon, authenticated;
revoke execute on function public.finalize_acceptance(uuid) from public, anon, authenticated;
revoke execute on function public.close_offers_on_booking_change() from public, anon, authenticated;
revoke execute on function public.moderate_message() from public, anon, authenticated;
revoke execute on function public.flag_message() from public, anon, authenticated;
revoke execute on function public.forbid_contact_in_listing() from public, anon, authenticated;
revoke execute on function public.forbid_contact_in_profile() from public, anon, authenticated;
revoke execute on function public.freeze_extension() from public, anon, authenticated;
revoke execute on function public.confirm_extension_payment(uuid, text, int, text, text) from public, anon, authenticated;
revoke execute on function public.close_extensions_on_booking_change() from public, anon, authenticated;
revoke execute on function public.expire_stale_bookings() from public, anon, authenticated;
revoke execute on function public.ledger_post(text, text, int, uuid, uuid, uuid, text, uuid, bigint) from public, anon, authenticated;
revoke execute on function public.ledger_on_extension_paid() from public, anon, authenticated;
revoke execute on function public.create_booking_agreement(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.agreement_on_booking_confirmed() from public, anon, authenticated;
revoke execute on function public.agreement_on_extension_paid() from public, anon, authenticated;
revoke execute on function public.domain_events_on_offer() from public, anon, authenticated;
revoke execute on function public.domain_events_on_extension() from public, anon, authenticated;

revoke execute on function public.accept_booking(uuid, time, time) from public, anon;
revoke execute on function public.counter_offer(uuid, int, time, time) from public, anon;
revoke execute on function public.accept_offer(uuid) from public, anon;
revoke execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean, int) from public, anon;
revoke execute on function public.quote_booking(uuid, date, date, int) from public, anon;
revoke execute on function public.submit_handover(uuid, text, int, int, text, text[], jsonb, numeric, numeric) from public, anon;
revoke execute on function public.confirm_handover(uuid) from public, anon;
revoke execute on function public.handover_comparison(uuid) from public, anon;
revoke execute on function public.transition_booking(uuid, public.booking_status, text) from public, anon;
revoke execute on function public.request_extension(uuid, date) from public, anon;
revoke execute on function public.respond_extension(uuid, boolean) from public, anon;
revoke execute on function public.cancel_extension(uuid) from public, anon;
revoke execute on function public.user_trust(uuid) from public, anon;
revoke execute on function public.vehicle_trust(uuid) from public, anon;
revoke execute on function public.contact_signals(text) from public, anon;
revoke execute on function public.mask_contact_data(text) from public, anon;

grant execute on function public.accept_booking(uuid, time, time) to authenticated;
grant execute on function public.counter_offer(uuid, int, time, time) to authenticated;
grant execute on function public.accept_offer(uuid) to authenticated;
grant execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean, int) to authenticated;
grant execute on function public.quote_booking(uuid, date, date, int) to authenticated;
grant execute on function public.submit_handover(uuid, text, int, int, text, text[], jsonb, numeric, numeric) to authenticated;
grant execute on function public.confirm_handover(uuid) to authenticated;
grant execute on function public.handover_comparison(uuid) to authenticated;
grant execute on function public.transition_booking(uuid, public.booking_status, text) to authenticated;
grant execute on function public.request_extension(uuid, date) to authenticated;
grant execute on function public.respond_extension(uuid, boolean) to authenticated;
grant execute on function public.cancel_extension(uuid) to authenticated;
grant execute on function public.user_trust(uuid) to authenticated;
grant execute on function public.vehicle_trust(uuid) to authenticated;
grant execute on function public.publish_offer_rule(public.vehicle_type, numeric, numeric, numeric, int, int, text, text) to authenticated, service_role;
grant execute on function public.confirm_extension_payment(uuid, text, int, text, text) to service_role;
grant execute on function public.expire_stale_bookings() to service_role;
