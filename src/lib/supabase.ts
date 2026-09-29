import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AppState, Platform } from 'react-native';

/**
 * Cliente de Supabase para la app.
 * Solo usa variables públicas (EXPO_PUBLIC_*). La service role key NUNCA va aquí.
 */
const url = process.env.EXPO_PUBLIC_SUPABASE_URL?.trim() ?? '';
const anonKey = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY?.trim() ?? '';

export const isSupabaseConfigured =
  /^https:\/\/.+/.test(url) && !url.includes('pega-aqui') && anonKey.length > 20 && !anonKey.includes('pega-aqui');

export const supabase: SupabaseClient = createClient(
  isSupabaseConfigured ? url : 'https://placeholder.supabase.co',
  isSupabaseConfigured ? anonKey : 'placeholder-key',
  {
    auth: {
      ...(Platform.OS !== 'web' ? { storage: AsyncStorage } : {}),
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: false,
    },
  },
);

// Renueva la sesión solo mientras la app está en primer plano.
if (Platform.OS !== 'web') {
  AppState.addEventListener('change', (state) => {
    if (state === 'active') {
      supabase.auth.startAutoRefresh();
    } else {
      supabase.auth.stopAutoRefresh();
    }
  });
}

export const VEHICLE_PHOTOS_BUCKET = 'vehicle-photos';

export function photoUrl(path: string | null | undefined): string | null {
  if (!path) return null;
  return supabase.storage.from(VEHICLE_PHOTOS_BUCKET).getPublicUrl(path).data.publicUrl;
}
