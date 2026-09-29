-- =============================================================================
-- RUÉ · 0004 · Pagos (Mercado Pago), tareas automáticas (cron) y envío de push
--
--   * payments.checkout_url: link de pago guardado para reutilizar la misma preferencia.
--   * record_payment_status(): el webhook registra pagos no aprobados (rechazado, pendiente…).
--   * pg_cron: vence solicitudes y reservas sin pago cada 10 minutos (sin depender de la app).
--   * pg_net: cada aviso nuevo llama a la Edge Function push-dispatch, que envía la notificación
--     push. Requiere configurar `supabase_url` en platform_settings (una línea, ver README).
-- =============================================================================

alter table public.payments add column if not exists checkout_url text;
alter table public.payments add column if not exists status_detail text;

-- Pagos no aprobados (rechazados, pendientes, reembolsados). Solo servidor.
create or replace function public.record_payment_status(
  p_booking_id uuid,
  p_provider_payment_id text,
  p_status text,
  p_status_detail text,
  p_amount_clp int,
  p_environment text
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  insert into public.payments (booking_id, environment, provider_payment_id, status, status_detail, amount_clp)
  values (p_booking_id, p_environment, p_provider_payment_id, p_status, p_status_detail, p_amount_clp)
  on conflict (provider, provider_payment_id)
  do update set status = excluded.status, status_detail = excluded.status_detail;

  if p_status = 'rejected' then
    insert into public.notifications (user_id, kind, title, body, booking_id)
    select b.renter_id, 'payment_failed', 'El pago no se aprobó',
           'Prueba con otro medio de pago antes de que venza tu reserva.', b.id
      from public.bookings b where b.id = p_booking_id and b.status = 'aceptada';
  end if;
end;
$$;

revoke execute on function public.record_payment_status(uuid, text, text, text, int, text) from public, anon, authenticated;
grant execute on function public.record_payment_status(uuid, text, text, text, int, text) to service_role;

-- -----------------------------------------------------------------------------
-- Configuración para llamadas internas servidor → Edge Functions
-- -----------------------------------------------------------------------------

insert into public.platform_settings (key, value, description) values
  ('supabase_url', 'null', 'URL del proyecto (https://xxxx.supabase.co). Necesaria para enviar notificaciones push.'),
  ('internal_webhook_secret', to_jsonb(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')),
   'Secreto que la base de datos envía a las Edge Functions internas. Se genera solo.')
on conflict (key) do nothing;

-- Envía cada aviso nuevo a push-dispatch (si pg_net y supabase_url están configurados).
create or replace function public.dispatch_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base text := (select value #>> '{}' from public.platform_settings where key = 'supabase_url');
  secret text := (select value #>> '{}' from public.platform_settings where key = 'internal_webhook_secret');
begin
  if base is null or base = '' or to_regnamespace('net') is null then
    return null;
  end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3)'
    using base || '/functions/v1/push-dispatch',
          jsonb_build_object('Content-Type', 'application/json', 'x-rue-secret', secret),
          jsonb_build_object('notification_id', new.id);
  return null;
exception when others then
  -- Nunca bloquear la operación principal por un problema de push; queda en el log.
  raise warning 'dispatch_push falló: %', sqlerrm;
  return null;
end;
$$;

revoke execute on function public.dispatch_push() from public, anon, authenticated;

drop trigger if exists notifications_dispatch_push on public.notifications;
create trigger notifications_dispatch_push
  after insert on public.notifications
  for each row execute function public.dispatch_push();

-- -----------------------------------------------------------------------------
-- Extensiones y tareas programadas (solo si están disponibles, como en Supabase)
-- -----------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  else
    raise notice 'pg_net no está disponible: las notificaciones push quedarán solo en la bandeja.';
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('rue-expire-bookings', '*/10 * * * *', 'select public.expire_stale_bookings()');
  else
    raise notice 'pg_cron no está disponible: expire_stale_bookings() no se programó.';
  end if;
end $$;
