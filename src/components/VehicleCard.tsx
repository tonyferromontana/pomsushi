import Ionicons from '@expo/vector-icons/Ionicons';
import MaterialCommunityIcons from '@expo/vector-icons/MaterialCommunityIcons';
import { Image } from 'expo-image';
import { memo } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { attributeSummary, vehicleTypeIcon, vehicleTypeLabel } from '@/lib/catalog';
import { photoUrl } from '@/lib/supabase';
import type { VehicleAttributes, VehicleType } from '@/lib/types';
import { colors, photoAspect, radius, space } from '@/theme';
import { Price, Text } from './ui';

export type VehicleCardData = {
  id: string;
  vehicle_type: VehicleType;
  title: string;
  brand: string;
  model: string;
  year: number;
  city: string;
  comuna: string | null;
  attributes: VehicleAttributes;
  daily_price_clp: number;
  verified: boolean;
  cover_path: string | null;
};

/** Foto del vehículo con placeholder consistente cuando no hay imagen */
export function VehiclePhoto({
  path,
  vehicleType,
  aspect = photoAspect,
  rounded = true,
}: {
  path: string | null;
  vehicleType: VehicleType;
  aspect?: number;
  rounded?: boolean;
}) {
  const uri = photoUrl(path);
  return (
    <View style={[styles.photo, { aspectRatio: aspect }, rounded && { borderRadius: radius.lg }]}>
      {uri ? (
        <Image
          source={{ uri }}
          style={StyleSheet.absoluteFill}
          contentFit="cover"
          transition={150}
          recyclingKey={path ?? undefined}
          accessibilityIgnoresInvertColors
        />
      ) : (
        <MaterialCommunityIcons name={vehicleTypeIcon(vehicleType)} size={48} color={colors.border} />
      )}
    </View>
  );
}

function VehicleCardBase({ v, onPress }: { v: VehicleCardData; onPress: () => void }) {
  const specs = attributeSummary(v.attributes, v.vehicle_type).slice(0, 3);
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${v.title}, ${v.daily_price_clp} pesos por día`}
      style={({ pressed }) => [styles.card, pressed && { opacity: 0.85 }]}
    >
      <VehiclePhoto path={v.cover_path} vehicleType={v.vehicle_type} />
      <View style={styles.body}>
        <View style={styles.topLine}>
          <Text variant="overline" color="textSecondary">
            {`${vehicleTypeLabel(v.vehicle_type)} · ${v.comuna || v.city}`.toUpperCase()}
          </Text>
          {v.verified ? <Ionicons name="shield-checkmark" size={14} color={colors.accent} /> : null}
        </View>
        <Text variant="h3" numberOfLines={1}>
          {v.title}
        </Text>
        <Text variant="bodySmall" color="textSecondary" numberOfLines={1}>
          {[`${v.brand} ${v.model} ${v.year}`, ...specs].join(' · ')}
        </Text>
        <View style={{ marginTop: space.xs }}>
          <Price amount={v.daily_price_clp} suffix="/ día" />
        </View>
      </View>
    </Pressable>
  );
}

export const VehicleCard = memo(VehicleCardBase);

const styles = StyleSheet.create({
  card: { gap: space.md },
  photo: {
    width: '100%',
    backgroundColor: colors.surface,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
  body: { gap: space.xxs },
  topLine: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
});
