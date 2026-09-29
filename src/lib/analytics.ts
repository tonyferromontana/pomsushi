/**
 * Eventos de producto. Todavía sin proveedor: en desarrollo se imprimen en consola.
 * Cuando elijamos proveedor, se conecta solo aquí.
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

export function track(event: AnalyticsEvent, props?: Record<string, string | number | boolean | null>): void {
  if (__DEV__) {
    console.log(`[analytics] ${event}`, props ?? {});
  }
}
