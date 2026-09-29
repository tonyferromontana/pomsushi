import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, RefreshControl, View } from 'react-native';

import { Badge, Card, EmptyState, ErrorState, LoadingState, Price, Screen, Segmented, Text } from '@/components/ui';
import { BOOKING_STATUS, vehicleTypeLabel } from '@/lib/catalog';
import { useAuth } from '@/lib/auth';
import { friendlyError } from '@/lib/errors';
import { dateRange, plural } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import type { Booking, VehicleType } from '@/lib/types';
import { useAsync } from '@/lib/useAsync';
import { colors, space } from '@/theme';

type Side = 'renter' | 'owner';
type BookingRow = Booking & { vehicle: { title: string; vehicle_type: VehicleType } | null };

async function loadBookings(userId: string, side: Side): Promise<BookingRow[]> {
  const { data, error } = await supabase
    .from('bookings')
    .select('*, vehicle:vehicles(title, vehicle_type)')
    .eq(side === 'renter' ? 'renter_id' : 'owner_id', userId)
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) throw error;
  return (data ?? []) as BookingRow[];
}

export default function BookingsScreen() {
  const { userId } = useAuth();
  const [side, setSide] = useState<Side>('renter');
  const { data, error, loading, reload } = useAsync(
    () => loadBookings(userId as string, side),
    [userId, side],
    !!userId,
  );

  useFocusEffect(
    useCallback(() => {
      void reload();
    }, [reload]),
  );

  return (
    <Screen>
      <View style={{ gap: space.lg, paddingTop: space.md, paddingBottom: space.lg }}>
        <Text variant="h1">Reservas</Text>
        <Segmented
          options={[
            { value: 'renter', label: 'Mis arriendos' },
            { value: 'owner', label: 'De mis vehículos' },
          ]}
          value={side}
          onChange={setSide}
        />
      </View>

      {loading && !data ? (
        <LoadingState />
      ) : error ? (
        <ErrorState message={friendlyError(error)} onRetry={reload} />
      ) : (
        <FlatList
          data={data}
          keyExtractor={(b) => b.id}
          contentContainerStyle={{ gap: space.md, paddingBottom: space.xxxl, flexGrow: 1 }}
          refreshControl={<RefreshControl refreshing={loading} onRefresh={reload} tintColor={colors.accent} />}
          ListEmptyComponent={
            side === 'renter' ? (
              <EmptyState
                icon="receipt-outline"
                title="Aún no tienes arriendos"
                body="Cuando solicites un vehículo, vas a ver aquí en qué va tu reserva."
              />
            ) : (
              <EmptyState
                icon="key-outline"
                title="Sin solicitudes por ahora"
                body="Cuando alguien quiera arrendar uno de tus vehículos, te llegará aquí."
              />
            )
          }
          renderItem={({ item: b }) => {
            const status = BOOKING_STATUS[b.status];
            const needsMe =
              (side === 'owner' && (b.status === 'solicitada' || b.status === 'confirmada' || b.status === 'en_curso' || b.status === 'devuelta')) ||
              (side === 'renter' && b.status === 'aceptada');
            return (
              <Card onPress={() => router.push({ pathname: '/booking/[id]', params: { id: b.id } })} style={{ gap: space.sm }}>
                <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                  <Badge label={status.label} tone={status.tone} />
                  {needsMe ? (
                    <Text variant="caption" color="accent">
                      Requiere tu acción
                    </Text>
                  ) : null}
                </View>
                <Text variant="h3" numberOfLines={1}>
                  {b.vehicle?.title ?? 'Vehículo'}
                </Text>
                <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-end' }}>
                  <Text variant="bodySmall" color="textSecondary">
                    {b.vehicle ? `${vehicleTypeLabel(b.vehicle.vehicle_type)} · ` : ''}
                    {dateRange(b.start_date, b.end_date)} · {plural(b.days, 'día', 'días')}
                  </Text>
                  <Price amount={side === 'owner' ? b.owner_payout_clp : b.total_clp} />
                </View>
              </Card>
            );
          }}
        />
      )}
    </Screen>
  );
}
