/**
 * RUÉ · Primitivas de interfaz.
 * Todas las pantallas se arman con estas piezas; los estilos salen de src/theme.ts.
 */
import Ionicons from '@expo/vector-icons/Ionicons';
import { Image } from 'expo-image';
import { forwardRef, useEffect, useState, type ComponentProps, type ReactNode } from 'react';
import {
  ActivityIndicator,
  Animated,
  Pressable,
  ScrollView,
  StyleSheet,
  Text as RNText,
  TextInput,
  View,
  type StyleProp,
  type TextInputProps,
  type TextProps as RNTextProps,
  type TextStyle,
  type ViewStyle,
} from 'react-native';
import { SafeAreaView, type Edge } from 'react-native-safe-area-context';

import { clp } from '@/lib/format';
import { colors, fonts, gutter, radius, size, space, type, type ColorToken, type TypeVariant } from '@/theme';

export type IconName = ComponentProps<typeof Ionicons>['name'];

// -----------------------------------------------------------------------------
// Texto
// -----------------------------------------------------------------------------

type TextProps = RNTextProps & {
  variant?: TypeVariant;
  color?: ColorToken;
  align?: TextStyle['textAlign'];
};

export function Text({ variant = 'body', color = 'text', align, style, ...rest }: TextProps) {
  return (
    <RNText
      {...rest}
      style={[type[variant], { color: colors[color] }, align ? { textAlign: align } : null, style]}
    />
  );
}

/** Logotipo tipográfico provisorio: RUÉ con el acento en lime. Se reemplaza por logo.svg cuando llegue. */
export function Wordmark({ size: fontSize = 28 }: { size?: number }) {
  return (
    <RNText
      accessibilityRole="header"
      accessibilityLabel="RUÉ"
      style={{ fontFamily: fonts.display, fontSize, lineHeight: fontSize * 1.1, color: colors.text, letterSpacing: -0.5 }}
    >
      RU<RNText style={{ color: colors.accent }}>É</RNText>
    </RNText>
  );
}

// -----------------------------------------------------------------------------
// Pantalla
// -----------------------------------------------------------------------------

type ScreenProps = {
  children: ReactNode;
  scroll?: boolean;
  padded?: boolean;
  edges?: Edge[];
  footer?: ReactNode;
  contentStyle?: StyleProp<ViewStyle>;
  refreshControl?: ComponentProps<typeof ScrollView>['refreshControl'];
};

export function Screen({
  children,
  scroll = false,
  padded = true,
  edges = ['top'],
  footer,
  contentStyle,
  refreshControl,
}: ScreenProps) {
  const inner = padded ? { paddingHorizontal: gutter } : null;
  return (
    <SafeAreaView style={styles.screen} edges={edges}>
      {scroll ? (
        <ScrollView
          contentContainerStyle={[inner, { paddingBottom: space.xxxl }, contentStyle]}
          keyboardShouldPersistTaps="handled"
          refreshControl={refreshControl}
        >
          {children}
        </ScrollView>
      ) : (
        <View style={[{ flex: 1 }, inner, contentStyle]}>{children}</View>
      )}
      {footer ? <View style={styles.footer}>{footer}</View> : null}
    </SafeAreaView>
  );
}

// -----------------------------------------------------------------------------
// Botones
// -----------------------------------------------------------------------------

type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';

type ButtonProps = {
  label: string;
  onPress?: () => void;
  variant?: ButtonVariant;
  loading?: boolean;
  disabled?: boolean;
  icon?: IconName;
  small?: boolean;
  style?: StyleProp<ViewStyle>;
};

export function Button({
  label,
  onPress,
  variant = 'primary',
  loading,
  disabled,
  icon,
  small,
  style,
}: ButtonProps) {
  const inactive = disabled || loading;
  const palette = {
    primary: { bg: colors.accent, pressed: colors.accentPressed, fg: colors.onAccent, border: colors.accent },
    secondary: { bg: colors.surface, pressed: colors.surfaceRaised, fg: colors.text, border: colors.border },
    ghost: { bg: 'transparent', pressed: colors.surface, fg: colors.text, border: 'transparent' },
    danger: { bg: 'transparent', pressed: colors.surface, fg: colors.error, border: colors.border },
  }[variant];

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled: !!inactive, busy: !!loading }}
      disabled={inactive}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        small && styles.buttonSmall,
        {
          backgroundColor: inactive && variant === 'primary' ? colors.disabled : pressed ? palette.pressed : palette.bg,
          borderColor: inactive && variant === 'primary' ? colors.disabled : palette.border,
        },
        style,
      ]}
    >
      {loading ? (
        <ActivityIndicator color={variant === 'primary' ? colors.onAccent : colors.text} />
      ) : (
        <>
          {icon ? (
            <Ionicons
              name={icon}
              size={small ? 16 : 20}
              color={inactive && variant === 'primary' ? colors.onDisabled : palette.fg}
            />
          ) : null}
          <RNText
            style={[
              small ? type.label : type.title,
              { color: inactive && variant === 'primary' ? colors.onDisabled : palette.fg },
            ]}
          >
            {label}
          </RNText>
        </>
      )}
    </Pressable>
  );
}

export function IconButton({
  icon,
  onPress,
  label,
  tone = 'text',
}: {
  icon: IconName;
  onPress: () => void;
  label: string;
  tone?: ColorToken;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      hitSlop={8}
      onPress={onPress}
      style={({ pressed }) => [styles.iconButton, pressed && { backgroundColor: colors.surfaceRaised }]}
    >
      <Ionicons name={icon} size={size.icon} color={colors[tone]} />
    </Pressable>
  );
}

// -----------------------------------------------------------------------------
// Campos
// -----------------------------------------------------------------------------

type InputProps = TextInputProps & {
  label?: string;
  hint?: string;
  error?: string | null;
  icon?: IconName;
};

export const Input = forwardRef<TextInput, InputProps>(function Input(
  { label, hint, error, icon, style, multiline, ...rest },
  ref,
) {
  return (
    <View style={{ gap: space.xs }}>
      {label ? <Text variant="label" color="textSecondary">{label}</Text> : null}
      <View
        style={[
          styles.inputWrap,
          multiline && { height: undefined, minHeight: 110, alignItems: 'flex-start', paddingVertical: space.md },
          error ? { borderColor: colors.error } : null,
        ]}
      >
        {icon ? <Ionicons name={icon} size={18} color={colors.textSecondary} /> : null}
        <TextInput
          ref={ref}
          placeholderTextColor={colors.textSecondary}
          selectionColor={colors.accent}
          multiline={multiline}
          style={[styles.input, multiline && { textAlignVertical: 'top' }, style]}
          {...rest}
        />
      </View>
      {error ? (
        <Text variant="caption" color="error">{error}</Text>
      ) : hint ? (
        <Text variant="caption" color="textSecondary">{hint}</Text>
      ) : null}
    </View>
  );
});

/** Campo que abre algo al tocarlo (fecha, selector). Se ve igual que Input. */
export function FieldButton({
  label,
  value,
  placeholder,
  icon,
  onPress,
  style,
}: {
  label?: string;
  value?: string | null;
  placeholder: string;
  icon?: IconName;
  onPress: () => void;
  style?: StyleProp<ViewStyle>;
}) {
  return (
    <View style={[{ gap: space.xs }, style]}>
      {label ? <Text variant="label" color="textSecondary">{label}</Text> : null}
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={label ?? placeholder}
        onPress={onPress}
        style={({ pressed }) => [styles.inputWrap, pressed && { backgroundColor: colors.surfaceRaised }]}
      >
        {icon ? <Ionicons name={icon} size={18} color={colors.textSecondary} /> : null}
        <Text variant="body" color={value ? 'text' : 'textSecondary'} numberOfLines={1} style={{ flex: 1 }}>
          {value || placeholder}
        </Text>
      </Pressable>
    </View>
  );
}

// -----------------------------------------------------------------------------
// Chips y selección
// -----------------------------------------------------------------------------

export function Chip({
  label,
  selected,
  onPress,
  leading,
}: {
  label: string;
  selected?: boolean;
  onPress?: () => void;
  leading?: ReactNode;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ selected: !!selected }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.chip,
        selected && { backgroundColor: colors.text, borderColor: colors.text },
        pressed && !selected && { backgroundColor: colors.surfaceRaised },
      ]}
    >
      {leading}
      <Text variant="label" color={selected ? 'textInverse' : 'text'}>
        {label}
      </Text>
    </Pressable>
  );
}

/** Tabs segmentadas (p. ej. "Arriendo" / "Mis vehículos") */
export function Segmented<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
}) {
  return (
    <View style={styles.segmented} accessibilityRole="tablist">
      {options.map((o) => {
        const active = o.value === value;
        return (
          <Pressable
            key={o.value}
            accessibilityRole="tab"
            accessibilityState={{ selected: active }}
            onPress={() => onChange(o.value)}
            style={[styles.segment, active && { backgroundColor: colors.surfaceRaised }]}
          >
            <Text variant="label" color={active ? 'text' : 'textSecondary'}>
              {o.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

// -----------------------------------------------------------------------------
// Contenedores
// -----------------------------------------------------------------------------

export function Card({
  children,
  style,
  onPress,
}: {
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  onPress?: () => void;
}) {
  if (onPress) {
    return (
      <Pressable
        onPress={onPress}
        style={({ pressed }) => [styles.card, pressed && { backgroundColor: colors.surfaceRaised }, style]}
      >
        {children}
      </Pressable>
    );
  }
  return <View style={[styles.card, style]}>{children}</View>;
}

export function Divider({ spacing = space.lg }: { spacing?: number }) {
  return <View style={{ height: size.hairline, backgroundColor: colors.border, marginVertical: spacing }} />;
}

export function SectionHeader({ title, action }: { title: string; action?: ReactNode }) {
  return (
    <View style={styles.sectionHeader}>
      <Text variant="h3">{title}</Text>
      {action}
    </View>
  );
}

export function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <View style={styles.row}>
      <Text variant={strong ? 'title' : 'bodySmall'} color={strong ? 'text' : 'textSecondary'}>
        {label}
      </Text>
      <Text variant={strong ? 'price' : 'bodySmall'}>{value}</Text>
    </View>
  );
}

// -----------------------------------------------------------------------------
// Datos
// -----------------------------------------------------------------------------

export function Badge({ label, tone = 'textSecondary' }: { label: string; tone?: ColorToken }) {
  return (
    <View style={[styles.badge, { borderColor: colors[tone] }]}>
      <View style={[styles.badgeDot, { backgroundColor: colors[tone] }]} />
      <Text variant="caption" color="text">
        {label}
      </Text>
    </View>
  );
}

export function Price({
  amount,
  suffix,
  large,
}: {
  amount: number;
  suffix?: string;
  large?: boolean;
}) {
  return (
    <Text variant={large ? 'priceLarge' : 'price'}>
      {clp(amount)}
      {suffix ? (
        <Text variant="bodySmall" color="textSecondary">
          {` ${suffix}`}
        </Text>
      ) : null}
    </Text>
  );
}

export function Avatar({ name, uri }: { name: string; uri?: string | null }) {
  const initial = (name.trim()[0] ?? '?').toUpperCase();
  if (uri) {
    return <Image source={{ uri }} style={styles.avatar} contentFit="cover" accessibilityLabel={name} />;
  }
  return (
    <View style={[styles.avatar, styles.avatarFallback]} accessibilityLabel={name}>
      <Text variant="title">{initial}</Text>
    </View>
  );
}

// -----------------------------------------------------------------------------
// Estados: cargando / vacío / error
// -----------------------------------------------------------------------------

export function Skeleton({ height = 16, width = '100%', style }: { height?: number; width?: ViewStyle['width']; style?: StyleProp<ViewStyle> }) {
  const [opacity] = useState(() => new Animated.Value(0.5));
  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(opacity, { toValue: 1, duration: 700, useNativeDriver: true }),
        Animated.timing(opacity, { toValue: 0.5, duration: 700, useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [opacity]);
  return (
    <Animated.View
      style={[{ height, width, borderRadius: radius.sm, backgroundColor: colors.surfaceRaised, opacity }, style]}
    />
  );
}

export function LoadingState({ label = 'Cargando…' }: { label?: string }) {
  return (
    <View style={styles.center} accessibilityLiveRegion="polite">
      <ActivityIndicator color={colors.accent} />
      <Text variant="bodySmall" color="textSecondary">
        {label}
      </Text>
    </View>
  );
}

export function EmptyState({
  icon = 'sparkles-outline',
  title,
  body,
  action,
}: {
  icon?: IconName;
  title: string;
  body?: string;
  action?: ReactNode;
}) {
  return (
    <View style={styles.center}>
      <View style={styles.emptyIcon}>
        <Ionicons name={icon} size={26} color={colors.accent} />
      </View>
      <Text variant="h3" align="center">
        {title}
      </Text>
      {body ? (
        <Text variant="bodySmall" color="textSecondary" align="center" style={{ maxWidth: 300 }}>
          {body}
        </Text>
      ) : null}
      {action ? <View style={{ marginTop: space.sm }}>{action}</View> : null}
    </View>
  );
}

export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <EmptyState
      icon="cloud-offline-outline"
      title="No pudimos cargar esto"
      body={message}
      action={onRetry ? <Button label="Reintentar" variant="secondary" icon="refresh" onPress={onRetry} small /> : null}
    />
  );
}

export function Notice({ tone = 'info', children }: { tone?: ColorToken; children: ReactNode }) {
  return (
    <View style={[styles.notice, { borderLeftColor: colors[tone] }]}>
      <Text variant="bodySmall">{children}</Text>
    </View>
  );
}

// -----------------------------------------------------------------------------

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  footer: {
    paddingHorizontal: gutter,
    paddingTop: space.md,
    paddingBottom: space.lg,
    borderTopWidth: size.hairline,
    borderTopColor: colors.border,
    backgroundColor: colors.background,
  },
  button: {
    height: size.control,
    borderRadius: radius.pill,
    borderWidth: 1,
    paddingHorizontal: space.xl,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
  },
  buttonSmall: { height: size.controlSmall, paddingHorizontal: space.lg },
  iconButton: {
    width: 40,
    height: 40,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  inputWrap: {
    height: size.control,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    paddingHorizontal: space.lg,
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  input: { flex: 1, color: colors.text, ...type.body, paddingVertical: 0, height: '100%' },
  chip: {
    height: size.controlSmall,
    paddingHorizontal: space.lg,
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.xs,
  },
  segmented: {
    flexDirection: 'row',
    backgroundColor: colors.surface,
    borderRadius: radius.pill,
    padding: space.xs,
    borderWidth: 1,
    borderColor: colors.border,
  },
  segment: {
    flex: 1,
    height: 36,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    padding: space.lg,
  },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: space.xl,
    marginBottom: space.md,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: space.xs,
  },
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: space.xs,
    paddingHorizontal: space.sm,
    paddingVertical: space.xxs,
    borderRadius: radius.pill,
    borderWidth: 1,
  },
  badgeDot: { width: 6, height: 6, borderRadius: 3 },
  avatar: { width: size.avatar, height: size.avatar, borderRadius: size.avatar / 2 },
  avatarFallback: {
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
    padding: space.xl,
    minHeight: 240,
  },
  emptyIcon: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: space.sm,
  },
  notice: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderLeftWidth: 3,
    padding: space.md,
  },
});
