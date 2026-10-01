import { logError } from './errors';
import { supabase } from './supabase';

/**
 * Eventos de producto. Todavía sin proveedor externo: en desarrollo se imprimen en consola.
 *
 * Los eventos de negocio (reserva, pago, devolución, payout, búsquedas) los registra
 * el SERVIDOR en domain_events; la app no puede inventarlos. Solo los que únicamente
 * conoce la app (ver un vehículo, abrir el pago) se envían con log_event().
 */
export type AnalyticsEvent =
  | 'signup_started'
  | 'signup_completed'
  | 'search'
  | 'vehicle_view'
  | 'booking_started'
  | 'booking_requested'
  | 'booking_accepted'
  | 'checkout_started'
  | 'payment_completed'
  | 'listing_started'
  | 'listing_completed';

type Props = Record<string, string | number | boolean | null>;

/** Eventos que se guardan en el servidor (domain_events) y con qué nombre. */
const SERVER_EVENTS: Partial<Record<AnalyticsEvent, 'vehicle_viewed' | 'checkout_started'>> = {
  vehicle_view: 'vehicle_viewed',
  checkout_started: 'checkout_started',
};

export function track(event: AnalyticsEvent, props?: Props, ids?: { vehicleId?: string; bookingId?: string }): void {
  if (__DEV__) {
    console.log(`[analytics] ${event}`, props ?? {});
  }
  const serverName = SERVER_EVENTS[event];
  if (!serverName) return;
  void supabase
    .rpc('log_event', {
      p_event_type: serverName,
      p_vehicle_id: ids?.vehicleId ?? null,
      p_booking_id: ids?.bookingId ?? null,
      p_props: props ?? {},
    })
    .then(({ error }) => {
      if (error) logError('analytics.log_event', error);
    });
}
