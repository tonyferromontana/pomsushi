-- =============================================================================
-- RUÉ · 0010 · booking_vehicle() devuelve el lugar de entrega de referencia
--
-- Para el botón "Ver en el mapa" de la reserva (abre Google Maps / Apple Maps con
-- la referencia que escribió el propietario; nunca una dirección exacta). Solo
-- participantes de la reserva, igual que antes.
-- =============================================================================

drop function if exists public.booking_vehicle(uuid);

create function public.booking_vehicle(p_booking_id uuid)
returns table (vehicle_id uuid, title text, vehicle_type public.vehicle_type, city text, comuna text, pickup_location text)
language sql
stable
security definer
set search_path = public
as $$
  select v.id, v.title, v.vehicle_type, v.city, v.comuna, v.pickup_location
  from public.bookings b join public.vehicles v on v.id = b.vehicle_id
  where b.id = p_booking_id and (b.owner_id = auth.uid() or b.renter_id = auth.uid())
$$;

revoke execute on function public.booking_vehicle(uuid) from public, anon;
grant execute on function public.booking_vehicle(uuid) to authenticated;
