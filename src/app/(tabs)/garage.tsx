import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, RefreshControl, View } from 'react-native';

import { Badge, Button, Card, EmptyState, ErrorState, LoadingState, Notice, Price, Screen, Text } from '@/components/ui';
import { VehiclePhoto } from '@/components/VehicleCard';
import { useAuth } from '@/lib/auth';
import { vehicleTypeLabel } from '@/lib/catalog';
import { friendlyError, logError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import type { ListingStatus, Vehicle } from '@/lib/types';
import { useAsync } from '@/lib/useAsync';
import { colors, space } from '@/theme';

type Row = Vehicle & { vehicle_photos: { storage_path: string; position: number }[] };

const STATUS_LABEL: Record<ListingStatus, { label: string; tone: 'accent' | 'warning' | 'textSecondary' }> = {
  publicado: { label: 'Publicado', tone: 'accent' },
  pausado: { label: 'Pausado', tone: 'warning' },
  borrador: { label: 'Borrador', tone: 'textSecondary' },
};

async function loadMine(userId: string): Promise<Row[]> {
  const { data, error } = await supabase
    .from('vehicles')
    .select('*, vehicle_photos(storage_path, position)')
    .eq('owner_id', userId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as Row[];
}

export default function GarageScreen() {
  const { userId } = useAuth();
  const { data, error, loading, reload } = useAsync(() => loadMine(userId as string), [userId], !!userId);
  const [toggling, setToggling] = useState<string | null>(null);
  const [toggleError, setToggleError] = useState<string | null>(null);

  useFocusEffect(
    useCallback(() => {
      void reload();
    }, [reload]),
  );

  const toggle = async (v: Row) => {
    setToggling(v.id);
    setToggleError(null);
    try {
      const next: ListingStatus = v.status === 'publicado' ? 'pausado' : 'publicado';
      const { error: err } = await supabase.from('vehicles').update({ status: next }).eq('id', v.id);
      if (err) throw err;
      await reload();
    } catch (e) {
      logError('vehicles.toggle', e);
      setToggleError(friendlyError(e));
    } finally {
      setToggling(null);
    }
  };

  const header = (
    <View style={{ gap: space.lg, paddingTop: space.md, paddingBottom: space.lg }}>
      <Text variant="h1">Mis vehículos</Text>
      {data && data.length > 0 ? (
        <Button label="Publicar otro vehículo" icon="add" variant="secondary" onPress={() => router.push('/publish')} />
      ) : null}
      {toggleError ? <Notice tone="error">{toggleError}</Notice> : null}
    </View>
  );

  if (loading && !data) return <LoadingState />;

  return (
    <Screen>
      {error ? (
        <>
          {header}
          <ErrorState message={friendlyError(error)} onRetry={reload} />
        </>
      ) : (
        <FlatList
          data={data}
          keyExtractor={(v) => v.id}
          ListHeaderComponent={header}
          contentContainerStyle={{ gap: space.lg, paddingBottom: space.xxxl, flexGrow: 1 }}
          refreshControl={<RefreshControl refreshing={loading} onRefresh={reload} tintColor={colors.accent} />}
          ListEmptyComponent={
            <EmptyState
              icon="key-outline"
              title="Haz producir lo que tienes parado"
              body="Publica tu auto, moto, camioneta o furgón y recibe solicitudes de personas y empresas que lo necesitan."
              action={<Button label="Publicar un vehículo" icon="add" onPress={() => router.push('/publish')} />}
            />
          }
          renderItem={({ item: v }) => {
            const cover = [...v.vehicle_photos].sort((a, b) => a.position - b.position)[0]?.storage_path ?? null;
            const st = STATUS_LABEL[v.status];
            return (
              <Card style={{ gap: space.md }} onPress={() => router.push({ pathname: '/vehicle/[id]', params: { id: v.id } })}>
                <View style={{ flexDirection: 'row', gap: space.md }}>
                  <View style={{ width: 96 }}>
                    <VehiclePhoto path={cover} vehicleType={v.vehicle_type} />
                  </View>
                  <View style={{ flex: 1, gap: space.xxs }}>
                    <Badge label={st.label} tone={st.tone} />
                    <Text variant="title" numberOfLines={1}>
                      {v.title}
                    </Text>
                    <Text variant="caption" color="textSecondary">
                      {vehicleTypeLabel(v.vehicle_type)} · {v.city}
                    </Text>
                    <Price amount={v.daily_price_clp} suffix="/ día" />
                  </View>
                </View>
                {v.vehicle_photos.length === 0 ? (
                  <Text variant="caption" color="warning">
                    Agrega fotos: las publicaciones con fotos reciben muchas más solicitudes.
                  </Text>
                ) : null}
                <View style={{ flexDirection: 'row', gap: space.sm }}>
                  <Button
                    small
                    variant="secondary"
                    label="Editar"
                    icon="create-outline"
                    style={{ flex: 1 }}
                    onPress={() => router.push({ pathname: '/publish', params: { id: v.id } })}
                  />
                  <Button
                    small
                    variant={v.status === 'publicado' ? 'secondary' : 'primary'}
                    label={v.status === 'publicado' ? 'Pausar' : 'Publicar'}
                    icon={v.status === 'publicado' ? 'pause' : 'play'}
                    style={{ flex: 1 }}
                    loading={toggling === v.id}
                    onPress={() => toggle(v)}
                  />
                </View>
              </Card>
            );
          }}
        />
      )}
    </Screen>
  );
}
