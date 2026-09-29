import { Stack, useLocalSearchParams } from 'expo-router';
import { View } from 'react-native';

import { EmptyState, Screen, Text } from '@/components/ui';
import { LEGAL_DOCS } from '@/legal/generated';
import { space } from '@/theme';

const TITLES = { terminos: 'Términos y Condiciones', privacidad: 'Privacidad' } as const;

/** Muestra un documento legal. Se puede abrir sin sesión (desde el registro). */
export default function LegalScreen() {
  const { doc } = useLocalSearchParams<{ doc: string }>();
  const key = doc === 'privacidad' ? 'privacidad' : doc === 'terminos' ? 'terminos' : null;

  if (!key) {
    return (
      <Screen>
        <EmptyState title="Documento no encontrado" />
      </Screen>
    );
  }

  return (
    <Screen scroll edges={['bottom']}>
      <Stack.Screen options={{ title: TITLES[key] }} />
      <View style={{ gap: space.md, paddingTop: space.lg }}>
        {LEGAL_DOCS[key].map((b, i) => {
          if (b.type === 'h1') return <Text key={i} variant="h1">{b.text}</Text>;
          if (b.type === 'h2') return <Text key={i} variant="h3" style={{ marginTop: space.lg }}>{b.text}</Text>;
          const text = b.text.replace(/\*\*(.+?)\*\*/g, '$1');
          if (b.type === 'li' || b.type === 'oli') {
            return (
              <View key={i} style={{ flexDirection: 'row', gap: space.sm, paddingLeft: space.sm }}>
                <Text color="textSecondary">{b.type === 'li' ? '•' : `${b.n}.`}</Text>
                <Text color="textSecondary" style={{ flex: 1 }}>{text}</Text>
              </View>
            );
          }
          return <Text key={i} color="textSecondary">{text}</Text>;
        })}
      </View>
    </Screen>
  );
}
