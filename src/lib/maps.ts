import { Linking, Platform } from 'react-native';

import { logError } from './errors';

/**
 * Abre el lugar de entrega en la app de mapas del teléfono (Apple Maps en iPhone,
 * Google Maps en Android). Solo usa la referencia que escribió el propietario
 * (ej: "Metro Tobalaba, Providencia"), nunca una dirección exacta ni GPS.
 */
export function openInMaps(parts: (string | null | undefined)[]): void {
  const query = parts
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(', ');
  if (!query) return;
  const q = encodeURIComponent(query);
  const url =
    Platform.OS === 'ios' ? `https://maps.apple.com/?q=${q}` : `https://www.google.com/maps/search/?api=1&query=${q}`;
  Linking.openURL(url).catch((e: unknown) => logError('maps.open', e));
}
