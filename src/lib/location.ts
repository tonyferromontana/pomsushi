import * as Location from 'expo-location';

export type ApproxPoint = { lat: number; lng: number };

/**
 * Ubicación APROXIMADA del teléfono, solo cuando la persona la pide.
 * Se redondea a ~1 km antes de salir del teléfono y no se guarda en el servidor
 * (para "cerca de mí"); el punto de un vehículo lo vuelve a redondear el servidor.
 */
export async function getApproxLocation(): Promise<ApproxPoint> {
  const perm = await Location.requestForegroundPermissionsAsync();
  if (!perm.granted) {
    throw new Error('Para buscar cerca necesitamos permiso de ubicación. Puedes darlo en los ajustes del teléfono.');
  }
  const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Low });
  const round = (n: number) => Math.round(n * 100) / 100;
  return { lat: round(pos.coords.latitude), lng: round(pos.coords.longitude) };
}
