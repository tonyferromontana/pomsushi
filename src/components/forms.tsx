import Ionicons from '@expo/vector-icons/Ionicons';
import type { ReactNode } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { colors, radius, space } from '@/theme';
import { Text } from './ui';

/** Casilla de aceptación (términos, declaraciones). */
export function Checkbox({
  checked,
  onChange,
  children,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  children: ReactNode;
}) {
  return (
    <Pressable
      accessibilityRole="checkbox"
      accessibilityState={{ checked }}
      onPress={() => onChange(!checked)}
      style={styles.row}
      hitSlop={4}
    >
      <View style={[styles.box, checked && { backgroundColor: colors.accent, borderColor: colors.accent }]}>
        {checked ? <Ionicons name="checkmark" size={16} color={colors.onAccent} /> : null}
      </View>
      <View style={{ flex: 1 }}>{typeof children === 'string' ? <Text variant="bodySmall">{children}</Text> : children}</View>
    </Pressable>
  );
}

/** Estrellas de 1 a 5. Si hay onChange, se pueden tocar. */
export function Stars({ value, onChange, size = 28 }: { value: number; onChange?: (v: number) => void; size?: number }) {
  return (
    <View style={styles.stars} accessibilityRole={onChange ? 'adjustable' : 'text'} accessibilityLabel={`${value} de 5 estrellas`}>
      {[1, 2, 3, 4, 5].map((n) => {
        const icon = (
          <Ionicons
            name={n <= Math.round(value) ? 'star' : 'star-outline'}
            size={size}
            color={n <= Math.round(value) ? colors.accent : colors.textSecondary}
          />
        );
        return onChange ? (
          <Pressable key={n} onPress={() => onChange(n)} hitSlop={6} accessibilityLabel={`${n} estrellas`}>
            {icon}
          </Pressable>
        ) : (
          <View key={n}>{icon}</View>
        );
      })}
    </View>
  );
}

/** Fila de menú (Perfil). */
export function MenuRow({
  icon,
  label,
  detail,
  onPress,
  tone = 'text',
}: {
  icon: React.ComponentProps<typeof Ionicons>['name'];
  label: string;
  detail?: string;
  onPress: () => void;
  tone?: 'text' | 'error';
}) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [styles.menuRow, pressed && { backgroundColor: colors.surfaceRaised }]}
    >
      <Ionicons name={icon} size={20} color={colors[tone]} />
      <Text variant="body" color={tone} style={{ flex: 1 }}>
        {label}
      </Text>
      {detail ? (
        <Text variant="caption" color="textSecondary">
          {detail}
        </Text>
      ) : null}
      <Ionicons name="chevron-forward" size={18} color={colors.textSecondary} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: space.md, alignItems: 'flex-start' },
  box: {
    width: 22,
    height: 22,
    borderRadius: radius.sm / 1.5,
    borderWidth: 1.5,
    borderColor: colors.textSecondary,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 1,
  },
  stars: { flexDirection: 'row', gap: space.xs },
  menuRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
    paddingVertical: space.md,
    paddingHorizontal: space.lg,
    borderRadius: radius.md,
  },
});
