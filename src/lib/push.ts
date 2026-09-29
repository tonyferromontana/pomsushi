import Constants from 'expo-constants';
import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import { router } from 'expo-router';
import { Platform } from 'react-native';

import { logError } from './errors';
import { supabase } from './supabase';

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true,
    shouldShowList: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
  }),
});

/** projectId de EAS (se crea con `eas init`). Sin él no hay token push. */
function easProjectId(): string | null {
  const extra = Constants.expoConfig?.extra as { eas?: { projectId?: string } } | undefined;
  return extra?.eas?.projectId ?? Constants.easConfig?.projectId ?? null;
}

/**
 * Pide permiso y guarda el token push del dispositivo.
 * Si no hay permiso, simulador o projectId, no hace nada (la bandeja de avisos sigue funcionando).
 */
export async function registerForPush(userId: string): Promise<void> {
  try {
    if (Platform.OS === 'web' || !Device.isDevice) return;
    const projectId = easProjectId();
    if (!projectId) {
      console.log('[RUÉ] Push desactivado: falta extra.eas.projectId (se crea con eas init).');
      return;
    }
    if (Platform.OS === 'android') {
      await Notifications.setNotificationChannelAsync('default', {
        name: 'Avisos de RUÉ',
        importance: Notifications.AndroidImportance.HIGH,
      });
    }
    const current = await Notifications.getPermissionsAsync();
    const status = current.granted ? 'granted' : (await Notifications.requestPermissionsAsync()).status;
    if (status !== 'granted') return;

    const { data: token } = await Notifications.getExpoPushTokenAsync({ projectId });
    const { error } = await supabase.from('push_tokens').upsert({
      token,
      user_id: userId,
      platform: Platform.OS === 'ios' ? 'ios' : 'android',
      updated_at: new Date().toISOString(),
    });
    if (error) throw error;
  } catch (e) {
    logError('push.register', e);
  }
}

/** Al tocar una notificación, abre la reserva correspondiente. */
export function listenToNotificationTaps(): () => void {
  if (Platform.OS === 'web') return () => undefined;
  const sub = Notifications.addNotificationResponseReceivedListener((response) => {
    const bookingId = (response.notification.request.content.data as { booking_id?: string } | undefined)?.booking_id;
    if (bookingId) router.push({ pathname: '/booking/[id]', params: { id: bookingId } });
  });
  return () => sub.remove();
}
