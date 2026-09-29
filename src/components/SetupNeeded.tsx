import { View } from 'react-native';

import { space } from '@/theme';
import { Notice, Screen, Text, Wordmark } from './ui';

/** Se muestra si falta el archivo .env con los datos de Supabase. */
export function SetupNeeded() {
  return (
    <Screen scroll>
      <View style={{ gap: space.lg, paddingTop: space.xxxl }}>
        <Wordmark size={40} />
        <Text variant="h2">Falta conectar la base de datos</Text>
        <Text color="textSecondary">
          La app funciona, pero todavía no sabe a qué proyecto de Supabase conectarse.
        </Text>
        <Notice tone="warning">
          Crea el archivo .env en la raíz del proyecto (copiando .env.example) y completa
          EXPO_PUBLIC_SUPABASE_URL y EXPO_PUBLIC_SUPABASE_ANON_KEY. Después reinicia con
          npx expo start --clear.
        </Notice>
      </View>
    </Screen>
  );
}
