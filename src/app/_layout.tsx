import {
  BricolageGrotesque_600SemiBold,
  BricolageGrotesque_700Bold,
} from '@expo-google-fonts/bricolage-grotesque';
import { DMSans_400Regular, DMSans_500Medium, DMSans_600SemiBold } from '@expo-google-fonts/dm-sans';
import { useFonts } from 'expo-font';
import { DarkTheme, Stack, ThemeProvider } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { View } from 'react-native';

import { SetupNeeded } from '@/components/SetupNeeded';
import { AuthProvider, useAuth } from '@/lib/auth';
import { isSupabaseConfigured } from '@/lib/supabase';
import { colors, fonts } from '@/theme';

SplashScreen.preventAutoHideAsync().catch(() => {
  // Si ya se ocultó (recarga en caliente), no hay nada que hacer.
});

const navTheme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    background: colors.background,
    card: colors.background,
    text: colors.text,
    border: colors.border,
    primary: colors.accent,
  },
};

function RootNavigator() {
  const { session, loading } = useAuth();

  if (loading) return <View style={{ flex: 1, backgroundColor: colors.background }} />;

  return (
    <Stack
      screenOptions={{
        headerStyle: { backgroundColor: colors.background },
        headerTintColor: colors.text,
        headerTitleStyle: { fontFamily: fonts.bodySemi },
        headerShadowVisible: false,
        headerBackButtonDisplayMode: 'minimal',
        contentStyle: { backgroundColor: colors.background },
      }}
    >
      <Stack.Protected guard={!!session}>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="vehicle/[id]" options={{ title: '', headerTransparent: true }} />
        <Stack.Screen name="booking/[id]" options={{ title: 'Reserva' }} />
        <Stack.Screen name="chat/[id]" options={{ title: 'Mensajes' }} />
        <Stack.Screen name="publish" options={{ title: 'Publicar', presentation: 'modal' }} />
      </Stack.Protected>
      <Stack.Protected guard={!session}>
        <Stack.Screen name="sign-in" options={{ headerShown: false }} />
      </Stack.Protected>
    </Stack>
  );
}

export default function RootLayout() {
  const [fontsLoaded, fontError] = useFonts({
    BricolageGrotesque_600SemiBold,
    BricolageGrotesque_700Bold,
    DMSans_400Regular,
    DMSans_500Medium,
    DMSans_600SemiBold,
  });

  const ready = fontsLoaded || !!fontError;

  useEffect(() => {
    if (fontError) console.warn('[RUÉ] No se pudieron cargar las fuentes', fontError);
    if (ready) SplashScreen.hideAsync().catch(() => undefined);
  }, [ready, fontError]);

  if (!ready) return null;

  return (
    <ThemeProvider value={navTheme}>
      <StatusBar style="light" />
      {isSupabaseConfigured ? (
        <AuthProvider>
          <RootNavigator />
        </AuthProvider>
      ) : (
        <SetupNeeded />
      )}
    </ThemeProvider>
  );
}
