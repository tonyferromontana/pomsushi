-- =============================================================================
-- RUÉ · 0008 · Configuración económica vigente del MVP (decisión del dueño, 2026-10-01)
--
--   * economic_config_versions: comisiones versionadas e inmutables.
--       - comisión al propietario: 15 % del arriendo base;
--       - cargo de servicio al arrendatario: 8 % del arriendo base;
--       - tratamiento de IVA: PENDIENTE DE CONTADOR (no se asume neto ni bruto);
--       - payout: T+2 días hábiles desde la devolución.
--     Reemplaza owner_commission_pct / renter_service_fee_pct de platform_settings.
--   * guarantee_rules: la garantía la define RUÉ por tipo de vehículo, no el
--     propietario. Preparada para condiciones futuras (valor, duración, riesgo,
--     historial, verificación). La garantía NO es ingreso ni GMV.
--   * bookings: + rental_extras_clp, gmv_clp, platform_gross_revenue_clp,
--     pricing_snapshot (reglas, tasas, versión e insumos con que se calculó),
--     economic_config_id, guarantee_rule_id. Todo congelado.
--   * ledger_entries: libro interno inmutable (bruto / neto / impuesto separados).
--   * payouts: estados pending → eligible → scheduled → paid (+ held, failed),
--     creados al DEVOLVER y elegibles a T+2 días hábiles salvo retención.
--   * domain_events: eventos de negocio originados en el servidor (+ búsquedas).
--   * booking_financials (vista) y marketplace_summary(): reporting desde el
--     ledger y los snapshots, nunca desde la configuración vigente.
--   * platform_settings_history: auditoría de cambios de configuración.
--
-- Convención de montos: CLP enteros. Mapeo con las columnas existentes de bookings:
--   rental_clp = arriendo base · owner_commission_clp = owner fee ·
--   renter_fee_clp = cargo de servicio · total_clp = monto cobrado (sin garantía) ·
--   owner_payout_clp = lo que recibe el propietario · deposit_clp = garantía.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Configuración económica versionada
-- -----------------------------------------------------------------------------

create table if not exists public.economic_config_versions (
  id                          bigint generated always as identity primary key,
  version                     text not null unique check (char_length(version) between 1 and 40),
  owner_fee_rate              numeric(6,5) not null check (owner_fee_rate >= 0 and owner_fee_rate < 1),
  renter_service_fee_rate     numeric(6,5) not null check (renter_service_fee_rate >= 0 and renter_service_fee_rate < 1),
  -- Base de cálculo de ambos cargos. Hoy solo el arriendo base.
  fee_base                    text not null default 'rental_base' check (fee_base in ('rental_base')),
  -- IVA: 'pending_accountant' = no se sabe si las tasas son netas o con IVA.
  -- Los otros valores quedan reservados; el cálculo se niega a usarlos hasta implementarlos.
  tax_treatment               text not null default 'pending_accountant'
                              check (tax_treatment in ('pending_accountant', 'fees_include_vat', 'vat_added_on_top', 'exempt')),
  payout_delay_business_days  int not null check (payout_delay_business_days between 0 and 30),
  effective_from              timestamptz not null default clock_timestamp(),
  notes                       text,
  created_by                  uuid,
  created_at                  timestamptz not null default clock_timestamp()
);

alter table public.economic_config_versions enable row level security;
-- Sin policies: solo el servidor (funciones security definer) y el panel de administración.
revoke all on public.economic_config_versions from anon, authenticated;
grant select on public.economic_config_versions to service_role;

-- Inmutable: una versión publicada nunca se edita ni se borra. Se publica otra.
create or replace function public.forbid_update_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Registro inmutable (%): publica una versión nueva en vez de modificarlo', tg_table_name
    using errcode = 'P0001';
end;
$$;

drop trigger if exists economic_config_immutable on public.economic_config_versions;
create trigger economic_config_immutable
  before update or delete on public.economic_config_versions
  for each row execute function public.forbid_update_delete();

insert into public.economic_config_versions
  (version, owner_fee_rate, renter_service_fee_rate, tax_treatment, payout_delay_business_days, effective_from, notes)
values
  ('mvp-2026-10-01', 0.15, 0.08, 'pending_accountant', 2, '2026-10-01 00:00:00-03',
   'MVP: comisión propietario 15 % y cargo de servicio arrendatario 8 % sobre el arriendo base. IVA pendiente de contador. Payout T+2 días hábiles.')
on conflict (version) do nothing;

-- Versión vigente = la última cuya fecha de vigencia ya llegó.
create or replace function public.active_economic_config()
returns public.economic_config_versions
language sql
stable
security definer
set search_path = public
as $$
  select * from public.economic_config_versions
  where effective_from <= clock_timestamp()
  order by effective_from desc, id desc
  limit 1
$$;

-- Publicar una versión nueva (solo admin o servidor). Afecta solo reservas nuevas.
create or replace function public.publish_economic_config(
  p_version text,
  p_owner_fee_rate numeric,
  p_renter_service_fee_rate numeric,
  p_payout_delay_business_days int,
  p_notes text,
  p_effective_from timestamptz default null
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
  if not public.is_admin() and auth.role() is distinct from 'service_role' then
    raise exception 'Solo un administrador puede cambiar la configuración económica' using errcode = '42501';
  end if;
  if coalesce(btrim(p_notes), '') = '' then
    raise exception 'Explica el motivo del cambio en las notas' using errcode = '22023';
  end if;
  insert into public.economic_config_versions
    (version, owner_fee_rate, renter_service_fee_rate, payout_delay_business_days, effective_from, notes, created_by)
  values
    (p_version, p_owner_fee_rate, p_renter_service_fee_rate, p_payout_delay_business_days,
     coalesce(p_effective_from, clock_timestamp()), p_notes, auth.uid())
  returning id into new_id;
  return new_id;
end;
$$;

-- Auditoría de cambios en platform_settings (plazos, exigencias, etc.)
create table if not exists public.platform_settings_history (
  id          bigint generated always as identity primary key,
  key         text not null,
  old_value   jsonb,
  new_value   jsonb,
  changed_by  uuid,
  db_user     text not null default current_user,
  changed_at  timestamptz not null default clock_timestamp()
);

alter table public.platform_settings_history enable row level security;
revoke all on public.platform_settings_history from anon, authenticated;

create or replace function public.log_platform_setting_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    insert into public.platform_settings_history (key, old_value, new_value, changed_by)
    values (old.key, old.value, null, auth.uid());
    return old;
  end if;
  if tg_op = 'INSERT' or new.value is distinct from old.value then
    insert into public.platform_settings_history (key, old_value, new_value, changed_by)
    values (new.key, case when tg_op = 'UPDATE' then old.value end, new.value, auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists platform_settings_audit on public.platform_settings;
create trigger platform_settings_audit
  after insert or update or delete on public.platform_settings
  for each row execute function public.log_platform_setting_change();

-- Una sola fuente de verdad para las comisiones: se retiran de platform_settings.
delete from public.platform_settings where key in ('owner_commission_pct', 'renter_service_fee_pct');

-- -----------------------------------------------------------------------------
-- 2. Reglas de garantía (las define RUÉ)
-- -----------------------------------------------------------------------------

create table if not exists public.guarantee_rules (
  id              bigint generated always as identity primary key,
  vehicle_type    public.vehicle_type not null,
  amount_clp      int not null check (amount_clp between 0 and 50000000),
  -- Condiciones futuras (valor del activo, duración, riesgo, historial, verificación).
  -- Hoy solo se aplican reglas sin condiciones ('{}'); una condición desconocida
  -- hace que la regla NO aplique (falla segura).
  conditions      jsonb not null default '{}'::jsonb check (jsonb_typeof(conditions) = 'object'),
  priority        int not null default 0,
  version         text not null,
  effective_from  timestamptz not null default clock_timestamp(),
  notes           text,
  created_by      uuid,
  created_at      timestamptz not null default clock_timestamp()
);

create index if not exists guarantee_rules_type_idx on public.guarantee_rules (vehicle_type, effective_from desc);

alter table public.guarantee_rules enable row level security;
revoke all on public.guarantee_rules from anon, authenticated;
grant select on public.guarantee_rules to service_role;

drop trigger if exists guarantee_rules_immutable on public.guarantee_rules;
create trigger guarantee_rules_immutable
  before update or delete on public.guarantee_rules
  for each row execute function public.forbid_update_delete();

insert into public.guarantee_rules (vehicle_type, amount_clp, version, effective_from, notes)
select t.vehicle_type::public.vehicle_type, t.amount, 'mvp-2026-10-01', '2026-10-01 00:00:00-03', t.note
from (values
  ('motorcycle', 150000, 'Moto'),
  ('car',        250000, 'Auto'),
  ('suv',        350000, 'SUV'),
  ('pickup',     350000, 'Camioneta'),
  ('van',        450000, 'Van'),
  ('cargo_van',  450000, 'Furgón'),
  ('minibus',    600000, 'Minibús'),
  ('truck',      800000, 'Camión'),
  ('trailer',    800000, 'Remolque (base)'),
  ('special',    800000, 'Especial (base)')
) as t(vehicle_type, amount, note)
where not exists (select 1 from public.guarantee_rules g where g.version = 'mvp-2026-10-01');

-- ¿La regla aplica a este contexto? Hoy: solo reglas sin condiciones.
create or replace function public.guarantee_rule_matches(p_conditions jsonb, p_context jsonb)
returns boolean
language sql
immutable
as $$
  select p_conditions = '{}'::jsonb
$$;

-- Garantía para un tipo y contexto (días, verificación, etc.). Devuelve la regla usada.
create or replace function public.resolve_guarantee(p_vehicle_type public.vehicle_type, p_context jsonb default '{}'::jsonb)
returns table (rule_id bigint, amount_clp int, rule_version text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
    select g.id, g.amount_clp, g.version
    from public.guarantee_rules g
    where g.vehicle_type = p_vehicle_type
      and g.effective_from <= clock_timestamp()
      and public.guarantee_rule_matches(g.conditions, coalesce(p_context, '{}'::jsonb))
    order by g.priority desc, g.effective_from desc, g.id desc
    limit 1;
  if not found then
    raise exception 'No hay una garantía definida para este tipo de vehículo' using errcode = 'P0001';
  end if;
end;
$$;

-- Para mostrar en la app (publicar / ficha) la garantía que fija RUÉ. Solo informa.
create or replace function public.guarantee_for_type(p_vehicle_type public.vehicle_type)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select amount_clp from public.resolve_guarantee(p_vehicle_type, '{}'::jsonb)
$$;

-- Publicar una regla nueva (solo admin o servidor).
create or replace function public.publish_guarantee_rule(
  p_vehicle_type public.vehicle_type,
  p_amount_clp int,
  p_version text,
  p_notes text,
  p_conditions jsonb default '{}'::jsonb,
  p_priority int default 0,
  p_effective_from timestamptz default null
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
  if not public.is_admin() and auth.role() is distinct from 'service_role' then
    raise exception 'Solo un administrador puede cambiar las garantías' using errcode = '42501';
  end if;
  if coalesce(btrim(p_notes), '') = '' then
    raise exception 'Explica el motivo del cambio en las notas' using errcode = '22023';
  end if;
  insert into public.guarantee_rules (vehicle_type, amount_clp, conditions, priority, version, effective_from, notes, created_by)
  values (p_vehicle_type, p_amount_clp, coalesce(p_conditions, '{}'::jsonb), coalesce(p_priority, 0), p_version,
          coalesce(p_effective_from, clock_timestamp()), p_notes, auth.uid())
  returning id into new_id;
  return new_id;
end;
$$;

-- El propietario ya no define la garantía: se quita el permiso sobre la columna.
revoke insert (deposit_clp), update (deposit_clp) on public.vehicles from authenticated;
comment on column public.vehicles.deposit_clp is
  'OBSOLETA desde 0008: la garantía la define RUÉ con guarantee_rules. No se usa para calcular reservas.';

-- -----------------------------------------------------------------------------
-- 3. Reservas: componentes económicos y snapshot
-- -----------------------------------------------------------------------------

alter table public.bookings add column if not exists rental_extras_clp          int not null default 0 check (rental_extras_clp >= 0);
alter table public.bookings add column if not exists gmv_clp                    int check (gmv_clp >= 0);
alter table public.bookings add column if not exists platform_gross_revenue_clp int check (platform_gross_revenue_clp >= 0);
alter table public.bookings add column if not exists pricing_snapshot           jsonb;
alter table public.bookings add column if not exists economic_config_id         bigint references public.economic_config_versions (id);
alter table public.bookings add column if not exists guarantee_rule_id          bigint references public.guarantee_rules (id);

comment on column public.bookings.deposit_clp is 'Garantía (definida por guarantee_rules desde 0008). NO es ingreso, NO es GMV, NO está en total_clp.';
comment on column public.bookings.total_clp is 'Monto cobrado al arrendatario = arriendo base + extras + cargo de servicio. Sin garantía.';
comment on column public.bookings.gmv_clp is 'GMV = arriendo base + extras ligados al uso del activo, antes de comisiones. Sin garantía, cargo de servicio, impuestos ni reembolsos.';
comment on column public.bookings.platform_gross_revenue_clp is 'Ingreso bruto de RUÉ = comisión propietario + cargo de servicio arrendatario.';
comment on column public.bookings.pricing_snapshot is 'Insumos, tasas, versión de configuración, regla de garantía y resultados con que se calculó la reserva. Inmutable.';

-- Reservas anteriores a 0008 (solo entornos de prueba): se completan con lo que ya tenían.
update public.bookings
   set gmv_clp = rental_clp + rental_extras_clp,
       platform_gross_revenue_clp = renter_fee_clp + owner_commission_clp,
       pricing_snapshot = jsonb_build_object('pricing_version', 'legacy-pre-0008', 'note', 'Reserva creada antes de la configuración versionada')
 where pricing_snapshot is null;

-- Precio (única fuente de verdad). Cambia las columnas de salida → se recrea.
drop function if exists public.compute_booking_price(uuid, date, date);
create function public.compute_booking_price(p_vehicle_id uuid, p_start date, p_end date)
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
  v       public.vehicles%rowtype;
  cfg     public.economic_config_versions%rowtype;
  g       record;
  n_days  int;
  rental  int;
  extras  int := 0;   -- Extras ligados al uso del activo (aún no existen en el producto).
  ctx     jsonb;
begin
  select * into v from public.vehicles where id = p_vehicle_id;
  if not found then
    raise exception 'Vehículo no encontrado' using errcode = 'P0002';
  end if;

  n_days := p_end - p_start;
  if n_days <= 0 then
    raise exception 'La fecha de término debe ser posterior a la de inicio' using errcode = '22023';
  end if;

  cfg := public.active_economic_config();
  if cfg.id is null then
    raise exception 'No hay configuración económica vigente' using errcode = 'P0001';
  end if;
  if cfg.tax_treatment <> 'pending_accountant' then
    -- Evita cálculos tributarios a medias: implementar en una migración nueva.
    raise exception 'Tratamiento tributario % aún no implementado', cfg.tax_treatment using errcode = 'P0001';
  end if;

  rental := n_days * v.daily_price_clp;
  if v.weekly_price_clp is not null and n_days >= 7 then
    rental := least(rental, (n_days / 7) * v.weekly_price_clp + (n_days % 7) * v.daily_price_clp);
  end if;

  ctx := jsonb_build_object(
    'vehicle_type', v.vehicle_type, 'days', n_days, 'vehicle_year', v.year,
    'vehicle_verified', v.verified
  );
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
    'pricing_version', 'rue-pricing-1',
    'computed_at', clock_timestamp(),
    'inputs', jsonb_build_object(
      'vehicle_id', v.id, 'vehicle_type', v.vehicle_type,
      'daily_price_clp', v.daily_price_clp, 'weekly_price_clp', v.weekly_price_clp,
      'start_date', p_start, 'end_date', p_end, 'days', n_days,
      'city', v.city, 'comuna', v.comuna
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

-- Cotización (misma firma; agrega garantía explícita, sigue sin tasas ni datos internos).
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
    'rental_extras_clp', p.rental_extras_clp,
    'renter_fee_clp', p.renter_fee_clp,
    'total_clp', p.total_clp,
    'deposit_clp', p.deposit_clp
  );
end;
$$;

-- request_booking (misma firma que 0006) guardando componentes y snapshot.
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
    rental_clp, rental_extras_clp, gmv_clp, renter_fee_clp, owner_commission_clp, total_clp,
    owner_payout_clp, deposit_clp, platform_gross_revenue_clp,
    economic_config_id, guarantee_rule_id, pricing_snapshot,
    renter_message, expires_at
  ) values (
    v.id, uid, v.owner_id, 'solicitada', p_purpose, p_start, p_end, p.days,
    p.rental_clp, p.rental_extras_clp, p.gmv_clp, p.renter_fee_clp, p.owner_commission_clp, p.total_clp,
    p.owner_payout_clp, p.deposit_clp, p.platform_gross_revenue_clp,
    p.economic_config_id, p.guarantee_rule_id, p.pricing_snapshot,
    nullif(btrim(left(p_message, 1000)), ''),
    now() + make_interval(hours => coalesce(public.setting_numeric('request_expiry_hours'), 24)::int)
  )
  returning id into new_id;

  insert into public.booking_consents (booking_id, user_id, terms_version, terms_accepted, data_sharing_accepted)
  values (new_id, uid, current_terms, true, true);

  return new_id;
end;
$$;

-- Congelamiento (reemplaza la de 0002): incluye los componentes nuevos y el snapshot.
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

  if (new.vehicle_id, new.renter_id, new.owner_id, new.start_date, new.end_date, new.days,
      new.rental_clp, new.rental_extras_clp, new.gmv_clp, new.renter_fee_clp, new.owner_commission_clp,
      new.total_clp, new.owner_payout_clp, new.deposit_clp, new.platform_gross_revenue_clp,
      new.economic_config_id, new.guarantee_rule_id, new.pricing_snapshot)
     is distinct from
     (old.vehicle_id, old.renter_id, old.owner_id, old.start_date, old.end_date, old.days,
      old.rental_clp, old.rental_extras_clp, old.gmv_clp, old.renter_fee_clp, old.owner_commission_clp,
      old.total_clp, old.owner_payout_clp, old.deposit_clp, old.platform_gross_revenue_clp,
      old.economic_config_id, old.guarantee_rule_id, old.pricing_snapshot) then
    raise exception 'Los datos económicos de una reserva no se pueden modificar' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Ledger interno (inmutable)
--
-- Signo, desde el punto de vista de RUÉ:
--   payment_received (+) dinero recibido · refund (−) dinero devuelto ·
--   owner_payout_paid (−) transferido al propietario · payment_processing_cost (−).
--   rental_base / rental_extra (+) GMV · owner_fee / renter_service_fee (+) ingreso ·
--   owner_payout_due (+) deuda con el propietario. Una cancelación posterior al pago
--   registra las mismas partidas con signo negativo (reversa).
-- gross_amount_clp = monto que efectivamente se mueve/calcula. net/tax quedan NULL
-- mientras el tratamiento de IVA esté pendiente del contador.
-- -----------------------------------------------------------------------------

create table if not exists public.ledger_entries (
  id                  bigint generated always as identity primary key,
  booking_id          uuid references public.bookings (id) on delete restrict,
  payment_id          uuid references public.payments (id) on delete restrict,
  payout_id           uuid references public.payouts (id) on delete restrict,
  entry_type          text not null check (entry_type in (
                        'payment_received', 'refund', 'payment_processing_cost',
                        'rental_base', 'rental_extra',
                        'owner_fee', 'renter_service_fee', 'other_platform_revenue',
                        'owner_payout_due', 'owner_payout_paid',
                        'guarantee_hold', 'guarantee_release', 'guarantee_capture',
                        'tax')),
  gross_amount_clp    int not null,
  net_amount_clp      int,
  tax_amount_clp      int,
  tax_status          text not null default 'pending_accountant'
                      check (tax_status in ('pending_accountant', 'not_applicable', 'determined')),
  counts_as_gmv       boolean not null default false,
  counts_as_revenue   boolean not null default false,
  economic_config_id  bigint references public.economic_config_versions (id),
  idempotency_key     text not null unique,
  memo                text,
  created_by          uuid,
  created_at          timestamptz not null default clock_timestamp(),
  -- Solo arriendo y extras cuentan como GMV; solo comisiones/cargos como ingreso.
  -- La garantía nunca es GMV ni ingreso.
  constraint ledger_gmv_types check (not counts_as_gmv or entry_type in ('rental_base', 'rental_extra')),
  constraint ledger_revenue_types check (not counts_as_revenue or entry_type in ('owner_fee', 'renter_service_fee', 'other_platform_revenue')),
  constraint ledger_guarantee_separate check (entry_type not like 'guarantee_%' or (not counts_as_gmv and not counts_as_revenue)),
  constraint ledger_tax_split check (
    (tax_status = 'determined' and net_amount_clp is not null and tax_amount_clp is not null
       and net_amount_clp + tax_amount_clp = gross_amount_clp)
    or (tax_status <> 'determined' and tax_amount_clp is null)
  )
);

create index if not exists ledger_booking_idx on public.ledger_entries (booking_id, created_at);
create index if not exists ledger_created_idx on public.ledger_entries (created_at);

alter table public.ledger_entries enable row level security;
revoke all on public.ledger_entries from anon, authenticated;
grant select on public.ledger_entries to service_role;

drop trigger if exists ledger_entries_immutable on public.ledger_entries;
create trigger ledger_entries_immutable
  before update or delete on public.ledger_entries
  for each row execute function public.forbid_update_delete();

create or replace function public.ledger_post(
  p_key text,
  p_entry_type text,
  p_amount int,
  p_booking_id uuid default null,
  p_payment_id uuid default null,
  p_payout_id uuid default null,
  p_memo text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  cfg_id bigint;
begin
  if p_amount is null or p_amount = 0 then
    return;
  end if;
  if p_booking_id is not null then
    select economic_config_id into cfg_id from public.bookings where id = p_booking_id;
  end if;
  insert into public.ledger_entries (
    booking_id, payment_id, payout_id, entry_type, gross_amount_clp, tax_status,
    counts_as_gmv, counts_as_revenue, economic_config_id, idempotency_key, memo, created_by
  ) values (
    p_booking_id, p_payment_id, p_payout_id, p_entry_type, p_amount,
    case when p_entry_type in ('owner_fee', 'renter_service_fee', 'other_platform_revenue', 'rental_base', 'rental_extra', 'payment_received', 'refund')
         then 'pending_accountant' else 'not_applicable' end,
    p_entry_type in ('rental_base', 'rental_extra'),
    p_entry_type in ('owner_fee', 'renter_service_fee', 'other_platform_revenue'),
    cfg_id, p_key, p_memo, auth.uid()
  )
  on conflict (idempotency_key) do nothing;
end;
$$;

-- Partidas de la reserva al confirmarse el pago y reversa si se cancela después.
create or replace function public.ledger_on_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  k text := 'booking:' || new.id || ':';
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
  end if;
  return null;
end;
$$;

drop trigger if exists bookings_ledger on public.bookings;
create trigger bookings_ledger
  after update of status on public.bookings
  for each row execute function public.ledger_on_booking_change();

-- Dinero que entra o sale por Webpay.
create or replace function public.ledger_on_payment_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  k text := 'payment:' || new.provider || ':' || coalesce(new.provider_payment_id, new.id::text) || ':';
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  if new.status = 'approved' then
    perform public.ledger_post(k || 'received', 'payment_received', new.amount_clp, new.booking_id, new.id);
  elsif new.status = 'refunded' then
    -- Un pago anulado también se recibió antes: ambas partidas quedan (neto 0).
    perform public.ledger_post(k || 'received', 'payment_received', new.amount_clp, new.booking_id, new.id);
    perform public.ledger_post(k || 'refund', 'refund', -new.amount_clp, new.booking_id, new.id, null, new.status_detail);
  end if;
  return null;
end;
$$;

drop trigger if exists payments_ledger on public.payments;
create trigger payments_ledger
  after insert or update of status on public.payments
  for each row execute function public.ledger_on_payment_change();

-- Admin: reembolso hecho a mano en el Portal de Transbank.
create or replace function public.record_manual_refund(p_booking_id uuid, p_amount_clp int, p_reference text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_admin() and auth.role() is distinct from 'service_role' then
    raise exception 'Solo un administrador puede registrar reembolsos' using errcode = '42501';
  end if;
  if p_amount_clp is null or p_amount_clp <= 0 or coalesce(btrim(p_reference), '') = '' then
    raise exception 'Indica el monto y la referencia del reembolso' using errcode = '22023';
  end if;
  if not exists (select 1 from public.bookings where id = p_booking_id) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  perform public.ledger_post('manual_refund:' || p_booking_id || ':' || btrim(p_reference), 'refund', -p_amount_clp,
                             p_booking_id, null, null, 'Reembolso manual ' || btrim(p_reference));
end;
$$;

-- Admin: costo de procesamiento (comisión de Transbank) cuando se conozca.
create or replace function public.record_processing_cost(p_booking_id uuid, p_amount_clp int, p_reference text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_admin() and auth.role() is distinct from 'service_role' then
    raise exception 'Solo un administrador puede registrar costos' using errcode = '42501';
  end if;
  if p_amount_clp is null or p_amount_clp < 0 or coalesce(btrim(p_reference), '') = '' then
    raise exception 'Indica el monto y la referencia' using errcode = '22023';
  end if;
  if not exists (select 1 from public.bookings where id = p_booking_id) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  perform public.ledger_post('processing_cost:' || p_booking_id || ':' || btrim(p_reference), 'payment_processing_cost',
                             -p_amount_clp, p_booking_id, null, null, btrim(p_reference));
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Pagos a propietarios: T+2 días hábiles desde la devolución
-- -----------------------------------------------------------------------------

create table if not exists public.business_holidays (
  day   date primary key,
  name  text not null
);

alter table public.business_holidays enable row level security;
revoke all on public.business_holidays from anon, authenticated;

-- Feriados nacionales de fecha conocida. Los movibles (San Pedro y San Pablo,
-- Encuentro de Dos Mundos, Pueblos Indígenas, Iglesias Evangélicas, elecciones)
-- los agrega el administrador cada año (OPERACION.md).
insert into public.business_holidays (day, name) values
  ('2026-01-01', 'Año Nuevo'), ('2026-04-03', 'Viernes Santo'), ('2026-05-01', 'Día del Trabajo'),
  ('2026-05-21', 'Glorias Navales'), ('2026-07-16', 'Virgen del Carmen'), ('2026-08-15', 'Asunción de la Virgen'),
  ('2026-09-18', 'Independencia Nacional'), ('2026-09-19', 'Glorias del Ejército'), ('2026-11-01', 'Todos los Santos'),
  ('2026-12-08', 'Inmaculada Concepción'), ('2026-12-25', 'Navidad'),
  ('2027-01-01', 'Año Nuevo'), ('2027-03-26', 'Viernes Santo'), ('2027-05-01', 'Día del Trabajo'),
  ('2027-05-21', 'Glorias Navales'), ('2027-07-16', 'Virgen del Carmen'), ('2027-08-15', 'Asunción de la Virgen'),
  ('2027-09-18', 'Independencia Nacional'), ('2027-09-19', 'Glorias del Ejército'), ('2027-11-01', 'Todos los Santos'),
  ('2027-12-08', 'Inmaculada Concepción'), ('2027-12-25', 'Navidad')
on conflict (day) do nothing;

create or replace function public.add_business_days(p_date date, p_days int)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d date := p_date;
  n int := 0;
begin
  while n < greatest(p_days, 0) loop
    d := d + 1;
    if extract(isodow from d) < 6 and not exists (select 1 from public.business_holidays h where h.day = d) then
      n := n + 1;
    end if;
  end loop;
  return d;
end;
$$;

-- Estados nuevos (se traducen los anteriores).
alter table public.payouts drop constraint if exists payouts_status_check;
update public.payouts set status = case status
  when 'pendiente' then 'pending' when 'pagado' then 'paid' when 'retenido' then 'held' else status end;
alter table public.payouts alter column status set default 'pending';
alter table public.payouts add constraint payouts_status_check
  check (status in ('pending', 'eligible', 'scheduled', 'paid', 'held', 'failed'));

alter table public.payouts add column if not exists eligible_on   date;
alter table public.payouts add column if not exists hold_reason   text check (hold_reason in (
  'damage_reported', 'open_dispute', 'late_return', 'unpaid_extra_charge', 'fraud_review', 'payment_issue'));
alter table public.payouts add column if not exists status_note   text;
alter table public.payouts add column if not exists scheduled_at  timestamptz;
alter table public.payouts add column if not exists failed_at     timestamptz;
alter table public.payouts add column if not exists updated_at    timestamptz not null default now();

create index if not exists payouts_status_idx on public.payouts (status, eligible_on);

-- Se reemplaza la creación al finalizar (0003) por la creación al devolver.
drop trigger if exists bookings_create_payout on public.bookings;
drop function if exists public.create_payout_on_finish();

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
begin
  if new.status is not distinct from old.status or new.confirmed_at is null then
    return null;
  end if;

  if new.status in ('devuelta', 'finalizada') then
    -- Desde una disputa resuelta se cuenta desde la resolución.
    base_day := (coalesce(case when new.status = 'devuelta' then new.returned_at end, now()) at time zone 'America/Santiago')::date;
    insert into public.payouts (booking_id, owner_id, amount_clp, status, eligible_on)
    values (new.id, new.owner_id, new.owner_payout_clp, 'pending', public.add_business_days(base_day, delay))
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

drop trigger if exists bookings_sync_payout on public.bookings;
create trigger bookings_sync_payout
  after update of status on public.bookings
  for each row execute function public.sync_payout_with_booking();

-- Cron: pending → eligible cuando llega la fecha.
create or replace function public.promote_eligible_payouts()
returns int
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n int;
begin
  update public.payouts
     set status = 'eligible', updated_at = now()
   where status = 'pending' and eligible_on is not null and eligible_on <= public.today_cl();
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.assert_admin_or_server()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() and auth.role() is distinct from 'service_role' then
    raise exception 'Solo un administrador puede hacer esto' using errcode = '42501';
  end if;
end;
$$;

-- Admin: programar (transferencia preparada), pagar, retener, liberar, marcar fallido.
create or replace function public.schedule_payout(p_payout_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.assert_admin_or_server();
  update public.payouts set status = 'scheduled', scheduled_at = now(), updated_at = now()
   where id = p_payout_id and status = 'eligible';
  if not found then
    raise exception 'Solo se puede programar un pago elegible' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.mark_payout_paid(p_payout_id uuid, p_reference text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  po public.payouts%rowtype;
begin
  perform public.assert_admin_or_server();
  if coalesce(btrim(p_reference), '') = '' then
    raise exception 'Indica el número de comprobante de la transferencia' using errcode = '22023';
  end if;
  update public.payouts
     set status = 'paid', paid_at = now(), reference = btrim(p_reference), updated_at = now()
   where id = p_payout_id and status in ('eligible', 'scheduled')
  returning * into po;
  if not found then
    raise exception 'Solo se puede pagar un pago elegible o programado (revisa que no esté retenido ni antes de plazo)' using errcode = 'P0001';
  end if;
  perform public.ledger_post('payout:' || po.id || ':paid', 'owner_payout_paid', -po.amount_clp, po.booking_id, null, po.id,
                             'Transferencia ' || po.reference);
end;
$$;

create or replace function public.hold_payout(p_payout_id uuid, p_reason text, p_note text default null)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.assert_admin_or_server();
  update public.payouts set status = 'held', hold_reason = p_reason, status_note = p_note, updated_at = now()
   where id = p_payout_id and status in ('pending', 'eligible', 'scheduled', 'failed');
  if not found then
    raise exception 'Ese pago no se puede retener (¿ya está pagado?)' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.release_payout(p_payout_id uuid, p_note text default null)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.assert_admin_or_server();
  update public.payouts
     set status = case when eligible_on is not null and eligible_on <= public.today_cl() then 'eligible' else 'pending' end,
         hold_reason = null, status_note = p_note, updated_at = now()
   where id = p_payout_id and status = 'held';
  if not found then
    raise exception 'Ese pago no está retenido' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.mark_payout_failed(p_payout_id uuid, p_note text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.assert_admin_or_server();
  update public.payouts set status = 'failed', failed_at = now(), status_note = p_note, updated_at = now()
   where id = p_payout_id and status in ('eligible', 'scheduled');
  if not found then
    raise exception 'Solo un pago elegible o programado puede marcarse como fallido' using errcode = 'P0001';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Eventos de dominio (originados en el servidor)
-- -----------------------------------------------------------------------------

create table if not exists public.domain_events (
  id           bigint generated always as identity primary key,
  event_type   text not null check (event_type in (
                 'user_created', 'vehicle_created', 'vehicle_published', 'vehicle_unpublished',
                 'search_performed', 'vehicle_viewed', 'booking_requested', 'booking_accepted',
                 'booking_rejected', 'booking_expired', 'checkout_started', 'payment_approved',
                 'payment_rejected', 'payment_refunded', 'booking_confirmed', 'booking_started',
                 'vehicle_returned', 'booking_completed', 'booking_cancelled', 'dispute_opened',
                 'dispute_closed', 'payout_eligible', 'payout_held', 'payout_paid')),
  source       text not null default 'server' check (source in ('server', 'client')),
  actor_id     uuid,
  booking_id   uuid,
  vehicle_id   uuid,
  payload      jsonb not null default '{}'::jsonb,
  occurred_at  timestamptz not null default clock_timestamp()
);

create index if not exists domain_events_type_idx on public.domain_events (event_type, occurred_at);
create index if not exists domain_events_booking_idx on public.domain_events (booking_id);

alter table public.domain_events enable row level security;
revoke all on public.domain_events from anon, authenticated;
grant select on public.domain_events to service_role;

create or replace function public.emit_domain_event(
  p_type text, p_booking_id uuid default null, p_vehicle_id uuid default null,
  p_payload jsonb default '{}'::jsonb, p_source text default 'server'
)
returns void
language sql
volatile
security definer
set search_path = public
as $$
  insert into public.domain_events (event_type, source, actor_id, booking_id, vehicle_id, payload)
  values (p_type, p_source, auth.uid(), p_booking_id, p_vehicle_id, coalesce(p_payload, '{}'::jsonb))
$$;

create or replace function public.domain_events_on_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.domain_events (event_type, actor_id, payload)
  values ('user_created', new.id, jsonb_build_object('city', new.city));
  return null;
end;
$$;

drop trigger if exists profiles_domain_events on public.profiles;
create trigger profiles_domain_events
  after insert on public.profiles
  for each row execute function public.domain_events_on_profile();

create or replace function public.domain_events_on_vehicle()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  geo jsonb := jsonb_build_object('vehicle_type', new.vehicle_type, 'city', new.city, 'comuna', new.comuna,
                                  'daily_price_clp', new.daily_price_clp);
begin
  if tg_op = 'INSERT' then
    perform public.emit_domain_event('vehicle_created', null, new.id, geo);
    if new.status = 'publicado' then
      perform public.emit_domain_event('vehicle_published', null, new.id, geo);
    end if;
  elsif new.status is distinct from old.status then
    if new.status = 'publicado' then
      perform public.emit_domain_event('vehicle_published', null, new.id, geo);
    elsif old.status = 'publicado' then
      perform public.emit_domain_event('vehicle_unpublished', null, new.id, geo || jsonb_build_object('to', new.status));
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists vehicles_domain_events on public.vehicles;
create trigger vehicles_domain_events
  after insert or update of status on public.vehicles
  for each row execute function public.domain_events_on_vehicle();

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
    'lead_days', new.start_date - (new.created_at at time zone 'America/Santiago')::date
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

drop trigger if exists bookings_domain_events on public.bookings;
create trigger bookings_domain_events
  after insert or update of status on public.bookings
  for each row execute function public.domain_events_on_booking();

create or replace function public.domain_events_on_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ev text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  ev := case new.status
    when 'approved' then 'payment_approved'
    when 'rejected' then 'payment_rejected'
    when 'refunded' then 'payment_refunded'
  end;
  if ev is not null then
    perform public.emit_domain_event(ev, new.booking_id, null, jsonb_build_object(
      'provider', new.provider, 'amount_clp', new.amount_clp, 'payment_type', new.payment_type,
      'installments', new.installments, 'environment', new.environment));
  end if;
  return null;
end;
$$;

drop trigger if exists payments_domain_events on public.payments;
create trigger payments_domain_events
  after insert or update of status on public.payments
  for each row execute function public.domain_events_on_payment();

create or replace function public.domain_events_on_payout()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ev text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  ev := case new.status
    when 'eligible' then 'payout_eligible'
    when 'held'     then 'payout_held'
    when 'paid'     then 'payout_paid'
  end;
  if ev is not null then
    perform public.emit_domain_event(ev, new.booking_id, null, jsonb_build_object(
      'amount_clp', new.amount_clp, 'eligible_on', new.eligible_on, 'hold_reason', new.hold_reason));
  end if;
  return null;
end;
$$;

drop trigger if exists payouts_domain_events on public.payouts;
create trigger payouts_domain_events
  after insert or update of status on public.payouts
  for each row execute function public.domain_events_on_payout();

-- Eventos que solo la app conoce (lista cerrada; el servidor pone quién y cuándo).
create or replace function public.log_event(
  p_event_type text, p_vehicle_id uuid default null, p_booking_id uuid default null, p_props jsonb default '{}'::jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return;
  end if;
  if p_event_type not in ('vehicle_viewed', 'checkout_started') then
    raise exception 'Evento no permitido' using errcode = '22023';
  end if;
  if p_props is not null and (jsonb_typeof(p_props) <> 'object' or length(p_props::text) > 2000) then
    raise exception 'Datos del evento inválidos' using errcode = '22023';
  end if;
  if p_booking_id is not null and not exists (
    select 1 from public.bookings b where b.id = p_booking_id and (b.renter_id = auth.uid() or b.owner_id = auth.uid())
  ) then
    raise exception 'Reserva no encontrada' using errcode = 'P0002';
  end if;
  perform public.emit_domain_event(p_event_type, p_booking_id, p_vehicle_id, coalesce(p_props, '{}'::jsonb), 'client');
end;
$$;

-- Búsqueda: misma firma y resultado que 0005; registra search_performed (primera página).
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
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n int;
begin
  return query
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
  offset greatest(p_offset, 0);

  get diagnostics n = row_count;
  if coalesce(p_offset, 0) = 0 then
    perform public.emit_domain_event('search_performed', null, null, jsonb_build_object(
      'vehicle_type', p_type, 'city', nullif(lower(btrim(p_city)), ''), 'purpose', p_purpose,
      'start_date', p_start, 'end_date', p_end, 'result_count', n, 'zero_result', n = 0));
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Reporting (solo administración): desde el ledger y los snapshots
-- -----------------------------------------------------------------------------

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
  -- NULL mientras el IVA esté pendiente del contador (no se inventa).
  case when coalesce(b.pricing_snapshot #>> '{economic_config,tax_treatment}', 'pending_accountant') = 'pending_accountant'
       then null else coalesce(l.tax, 0) end                as tax_amount,
  l.processing_cost                      as payment_processing_cost,
  coalesce(l.refunds, 0)                 as refunds,
  b.owner_payout_clp                     as owner_payout,
  po.status                              as payout_status,
  po.eligible_on                         as payout_eligible_on,
  b.platform_gross_revenue_clp           as platform_gross_revenue,
  -- Ingreso neto: solo cuando se conoce el IVA y el costo de procesamiento.
  case when coalesce(b.pricing_snapshot #>> '{economic_config,tax_treatment}', 'pending_accountant') = 'pending_accountant'
            or l.processing_cost is null then null
       else b.platform_gross_revenue_clp - l.processing_cost - coalesce(l.tax, 0) end as platform_net_revenue
from public.bookings b
left join public.payouts po on po.booking_id = b.id
left join lateral (
  select
    -sum(e.gross_amount_clp) filter (where e.entry_type = 'refund')                  as refunds,
    -sum(e.gross_amount_clp) filter (where e.entry_type = 'payment_processing_cost') as processing_cost,
    sum(e.tax_amount_clp)    filter (where e.tax_status = 'determined')              as tax
  from public.ledger_entries e where e.booking_id = b.id
) l on true;

revoke all on public.booking_financials from anon, authenticated;
grant select on public.booking_financials to service_role;

-- Resumen del marketplace para un período (fechas de Chile, [desde, hasta]).
-- GMV e ingresos salen del ledger (incluye reversas); nunca de la configuración vigente.
create or replace function public.marketplace_summary(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t0 timestamptz := (p_from::timestamp at time zone 'America/Santiago');
  t1 timestamptz := ((p_to + 1)::timestamp at time zone 'America/Santiago');
  gmv bigint; rev bigint; owner_fees bigint; renter_fees bigint; refunds bigint; received bigint;
  completed int; confirmed int; requested int; cancelled_after_pay int;
  searches int; zero_searches int;
begin
  perform public.assert_admin_or_server();

  select coalesce(sum(gross_amount_clp) filter (where counts_as_gmv), 0),
         coalesce(sum(gross_amount_clp) filter (where counts_as_revenue), 0),
         coalesce(sum(gross_amount_clp) filter (where entry_type = 'owner_fee'), 0),
         coalesce(sum(gross_amount_clp) filter (where entry_type = 'renter_service_fee'), 0),
         coalesce(-sum(gross_amount_clp) filter (where entry_type = 'refund'), 0),
         coalesce(sum(gross_amount_clp) filter (where entry_type = 'payment_received'), 0)
    into gmv, rev, owner_fees, renter_fees, refunds, received
    from public.ledger_entries where created_at >= t0 and created_at < t1;

  select count(*) filter (where event_type = 'booking_completed'),
         count(*) filter (where event_type = 'booking_confirmed'),
         count(*) filter (where event_type = 'booking_requested'),
         count(*) filter (where event_type = 'booking_cancelled' and payload ->> 'from' in ('confirmada', 'en_curso', 'devuelta', 'disputada')),
         count(*) filter (where event_type = 'search_performed'),
         count(*) filter (where event_type = 'search_performed' and (payload ->> 'zero_result')::boolean)
    into completed, confirmed, requested, cancelled_after_pay, searches, zero_searches
    from public.domain_events where occurred_at >= t0 and occurred_at < t1;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'gmv_clp', gmv,
    'platform_gross_revenue_clp', rev,
    'owner_fee_clp', owner_fees,
    'renter_service_fee_clp', renter_fees,
    'effective_take_rate', case when gmv > 0 then round(rev::numeric / gmv, 4) end,
    'payments_received_clp', received,
    'refunds_clp', refunds,
    'platform_net_revenue_clp', null,
    'net_revenue_note', 'Pendiente: tratamiento de IVA (contador) y costos de Transbank',
    'bookings_requested', requested,
    'bookings_confirmed', confirmed,
    'bookings_completed', completed,
    'bookings_cancelled_after_payment', cancelled_after_pay,
    'searches', searches,
    'zero_result_searches', zero_searches,
    'average_booking_value_clp', case when confirmed > 0 then round(gmv::numeric / confirmed) end
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Cron y permisos
-- -----------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('rue-promote-payouts', '7 * * * *', 'select public.promote_eligible_payouts()');
  else
    raise notice 'pg_cron no está disponible: promote_eligible_payouts() no se programó.';
  end if;
end $$;

revoke execute on function public.forbid_update_delete() from public, anon, authenticated;
revoke execute on function public.active_economic_config() from public, anon, authenticated;
revoke execute on function public.publish_economic_config(text, numeric, numeric, int, text, timestamptz) from public, anon;
revoke execute on function public.log_platform_setting_change() from public, anon, authenticated;
revoke execute on function public.guarantee_rule_matches(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.resolve_guarantee(public.vehicle_type, jsonb) from public, anon, authenticated;
revoke execute on function public.guarantee_for_type(public.vehicle_type) from public, anon;
revoke execute on function public.publish_guarantee_rule(public.vehicle_type, int, text, text, jsonb, int, timestamptz) from public, anon;
revoke execute on function public.compute_booking_price(uuid, date, date) from public, anon, authenticated;
revoke execute on function public.ledger_post(text, text, int, uuid, uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.ledger_on_booking_change() from public, anon, authenticated;
revoke execute on function public.ledger_on_payment_change() from public, anon, authenticated;
revoke execute on function public.record_manual_refund(uuid, int, text) from public, anon;
revoke execute on function public.record_processing_cost(uuid, int, text) from public, anon;
revoke execute on function public.add_business_days(date, int) from public, anon, authenticated;
revoke execute on function public.sync_payout_with_booking() from public, anon, authenticated;
revoke execute on function public.promote_eligible_payouts() from public, anon, authenticated;
revoke execute on function public.assert_admin_or_server() from public, anon, authenticated;
revoke execute on function public.schedule_payout(uuid) from public, anon;
revoke execute on function public.mark_payout_paid(uuid, text) from public, anon;
revoke execute on function public.hold_payout(uuid, text, text) from public, anon;
revoke execute on function public.release_payout(uuid, text) from public, anon;
revoke execute on function public.mark_payout_failed(uuid, text) from public, anon;
revoke execute on function public.emit_domain_event(text, uuid, uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function public.domain_events_on_profile() from public, anon, authenticated;
revoke execute on function public.domain_events_on_vehicle() from public, anon, authenticated;
revoke execute on function public.domain_events_on_booking() from public, anon, authenticated;
revoke execute on function public.domain_events_on_payment() from public, anon, authenticated;
revoke execute on function public.domain_events_on_payout() from public, anon, authenticated;
revoke execute on function public.log_event(text, uuid, uuid, jsonb) from public, anon;
revoke execute on function public.marketplace_summary(date, date) from public, anon;
revoke execute on function public.quote_booking(uuid, date, date) from public, anon;
revoke execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean) from public, anon;
revoke execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) from public, anon;

-- Funciones de administración: authenticated puede llamarlas, pero adentro exigen is_admin().
grant execute on function public.publish_economic_config(text, numeric, numeric, int, text, timestamptz) to authenticated, service_role;
grant execute on function public.publish_guarantee_rule(public.vehicle_type, int, text, text, jsonb, int, timestamptz) to authenticated, service_role;
grant execute on function public.record_manual_refund(uuid, int, text) to authenticated, service_role;
grant execute on function public.record_processing_cost(uuid, int, text) to authenticated, service_role;
grant execute on function public.schedule_payout(uuid) to authenticated, service_role;
grant execute on function public.mark_payout_paid(uuid, text) to authenticated, service_role;
grant execute on function public.hold_payout(uuid, text, text) to authenticated, service_role;
grant execute on function public.release_payout(uuid, text) to authenticated, service_role;
grant execute on function public.mark_payout_failed(uuid, text) to authenticated, service_role;
grant execute on function public.marketplace_summary(date, date) to authenticated, service_role;
grant execute on function public.promote_eligible_payouts() to service_role;

grant execute on function public.guarantee_for_type(public.vehicle_type) to authenticated;
grant execute on function public.log_event(text, uuid, uuid, jsonb) to authenticated;
grant execute on function public.quote_booking(uuid, date, date) to authenticated;
grant execute on function public.request_booking(uuid, date, date, public.booking_purpose, text, text, boolean, boolean) to authenticated;
grant execute on function public.search_vehicles(public.vehicle_type, text, date, date, public.booking_purpose, int, int) to authenticated;
