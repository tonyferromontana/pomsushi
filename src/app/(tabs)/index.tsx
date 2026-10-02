import Ionicons from '@expo/vector-icons/Ionicons';
import MaterialCommunityIcons from '@expo/vector-icons/MaterialCommunityIcons';
import { router, useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { FlatList, Pressable, RefreshControl, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { DateRangeField } from '@/components/DateRangeField';
import { Chip, EmptyState, ErrorState, Input, Skeleton, Text, Wordmark } from '@/components/ui';
import { VehicleCard } from '@/components/VehicleCard';
import { track } from '@/lib/analytics';
import { useAuth } from '@/lib/auth';
import { PURPOSES, VEHICLE_TYPES } from '@/lib/catalog';
import { friendlyError, logError } from '@/lib/errors';
import { getApproxLocation, type ApproxPoint } from '@/lib/location';
import { supabase } from '@/lib/supabase';
import { useAsync } from '@/lib/useAsync';
import type { BookingPurpose, VehicleSearchResult, VehicleType } from '@/lib/types';
import { colors, gutter, space } from '@/theme';

const PAGE_SIZE = 20;

type Filters = {
  type: VehicleType | null;
  city: string;
  start: string | null;
  end: string | null;
  purpose: BookingPurpose | null;
  /** "Cerca de mí": punto aproximado del teléfono (no se guarda) y radio en km */
  near: ApproxPoint | null;
  radiusKm: number;
};

const RADII = [10, 25, 50];

async function fetchPage(f: Filters, offset: number): Promise<VehicleSearchResult[]> {
  const { data, error } = await supabase.rpc('search_vehicles', {
    p_type: f.type,
    p_city: f.city.trim() || null,
    p_start: f.start && f.end ? f.start : null,
    p_end: f.start && f.end ? f.end : null,
    p_purpose: f.purpose,
    p_limit: PAGE_SIZE,
    p_offset: offset,
    p_near_lat: f.near?.lat ?? null,
    p_near_lng: f.near?.lng ?? null,
    p_radius_km: f.near ? f.radiusKm : null,
  });
  if (error) throw error;
  return (data ?? []) as VehicleSearchResult[];
}

export default function ExploreScreen() {
  const [filters, setFilters] = useState<Filters>({
    type: null,
    city: '',
    start: null,
    end: null,
    purpose: null,
    near: null,
    radiusKm: 25,
  });
  const [locating, setLocating] = useState(false);
  const [nearError, setNearError] = useState<string | null>(null);

  const toggleNear = async () => {
    setNearError(null);
    if (filters.near) {
      setFilters((f) => ({ ...f, near: null }));
      return;
    }
    setLocating(true);
    try {
      const near = await getApproxLocation();
      setFilters((f) => ({ ...f, near }));
    } catch (e) {
      logError('explore.location', e);
      setNearError(e instanceof Error ? e.message : friendlyError(e));
    } finally {
      setLocating(false);
    }
  };
  const [cityDraft, setCityDraft] = useState('');
  const { userId } = useAuth();
  const [unread, setUnread] = useState(0);

  // Cantidad de avisos sin leer (se actualiza al volver a esta pantalla)
  useFocusEffect(
    useCallback(() => {
      if (!userId) return;
      let alive = true;
      supabase
        .from('notifications')
        .select('id', { count: 'exact', head: true })
        .eq('user_id', userId)
        .is('read_at', null)
        .then(({ count, error: err }) => {
          if (err) logError('notifications.count', err);
          else if (alive) setUnread(count ?? 0);
        });
      return () => {
        alive = false;
      };
    }, [userId]),
  );

  const filtersKey = JSON.stringify(filters);
  const first = useAsync(() => fetchPage(filters, 0), [filtersKey]);
  const [extra, setExtra] = useState<{ key: string; items: VehicleSearchResult[]; done: boolean } | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const items = useMemo(
    () => [...(first.data ?? []), ...(extra?.key === filtersKey ? extra.items : [])],
    [first.data, extra, filtersKey],
  );
  const hasMore =
    extra?.key === filtersKey ? !extra.done : (first.data?.length ?? 0) === PAGE_SIZE;
  const loading = first.loading && !refreshing;
  const error = first.error;

  useEffect(() => {
    if (first.data) {
      track('search', {
        type: filters.type,
        has_dates: !!(filters.start && filters.end),
        purpose: filters.purpose,
        results: first.data.length,
      });
    }
    // Solo cuando llega una búsqueda nueva
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [first.data]);

  const refresh = async () => {
    setRefreshing(true);
    setExtra(null);
    try {
      await first.reload();
    } finally {
      setRefreshing(false);
    }
  };

  const loadMore = async () => {
    if (loadingMore || first.loading || !hasMore || error || !first.data) return;
    const key = filtersKey;
    setLoadingMore(true);
    try {
      const page = await fetchPage(filters, items.length);
      setExtra((prev) => ({
        key,
        items: [...(prev?.key === key ? prev.items : []), ...page],
        done: page.length < PAGE_SIZE,
      }));
    } catch (e) {
      logError('search_vehicles.more', e);
      setExtra((prev) => ({ key, items: prev?.key === key ? prev.items : [], done: true }));
    } finally {
      setLoadingMore(false);
    }
  };

  const openVehicle = useCallback(
    (id: string) => {
      const params: Record<string, string> = { id };
      if (filters.start && filters.end) {
        params.start = filters.start;
        params.end = filters.end;
      }
      if (filters.purpose) params.purpose = filters.purpose;
      router.push({ pathname: '/vehicle/[id]', params: params as { id: string } });
    },
    [filters.start, filters.end, filters.purpose],
  );

  const header = (
    <View style={{ gap: space.lg, paddingBottom: space.xl }}>
      <View style={styles.topBar}>
        <Wordmark size={26} />
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={unread ? `Avisos, ${unread} sin leer` : 'Avisos'}
          onPress={() => router.push('/notifications')}
          hitSlop={8}
        >
          <Ionicons name="notifications-outline" size={24} color={colors.text} />
          {unread ? <View style={styles.unreadDot} /> : null}
        </Pressable>
      </View>
      <Text variant="h1">¿Qué necesitas mover?</Text>

      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={{ gap: space.sm, paddingHorizontal: gutter }}
        style={{ marginHorizontal: -gutter }}
      >
        <Chip label="Todo" selected={filters.type === null} onPress={() => setFilters((f) => ({ ...f, type: null }))} />
        {VEHICLE_TYPES.map((t) => {
          const selected = filters.type === t.value;
          return (
            <Chip
              key={t.value}
              label={t.label}
              selected={selected}
              onPress={() => setFilters((f) => ({ ...f, type: selected ? null : t.value }))}
              leading={
                <MaterialCommunityIcons
                  name={t.icon}
                  size={16}
                  color={selected ? colors.textInverse : colors.textSecondary}
                />
              }
            />
          );
        })}
      </ScrollView>

      <Input
        icon="location-outline"
        placeholder="Ciudad o comuna"
        value={cityDraft}
        onChangeText={setCityDraft}
        returnKeyType="search"
        autoCorrect={false}
      />

      <View style={{ gap: space.sm }}>
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={{ gap: space.sm, paddingHorizontal: gutter }}
          style={{ marginHorizontal: -gutter }}
        >
          <Chip
            label={locating ? 'Buscando tu ubicación…' : 'Cerca de mí'}
            selected={!!filters.near}
            onPress={toggleNear}
            leading={
              <Ionicons name="navigate-outline" size={16} color={filters.near ? colors.textInverse : colors.textSecondary} />
            }
          />
          {filters.near
            ? RADII.map((r) => (
                <Chip
                  key={r}
                  label={`${r} km`}
                  selected={filters.radiusKm === r}
                  onPress={() => setFilters((f) => ({ ...f, radiusKm: r }))}
                />
              ))
            : null}
        </ScrollView>
        {nearError ? (
          <Text variant="caption" color="warning">
            {nearError}
          </Text>
        ) : null}
        {filters.near ? (
          <Text variant="caption" color="textSecondary">
            Usamos tu ubicación aproximada solo para ordenar esta búsqueda; no la guardamos.
          </Text>
        ) : null}
      </View>

      <DateRangeField
        start={filters.start}
        end={filters.end}
        onChange={(start, end) => setFilters((f) => ({ ...f, start, end }))}
      />

      <View style={{ gap: space.sm }}>
        <Text variant="label" color="textSecondary">
          ¿Para qué? (opcional)
        </Text>
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={{ gap: space.sm, paddingHorizontal: gutter }}
          style={{ marginHorizontal: -gutter }}
        >
          {PURPOSES.map((p) => {
            const selected = filters.purpose === p.value;
            return (
              <Chip
                key={p.value}
                label={p.label}
                selected={selected}
                onPress={() => setFilters((f) => ({ ...f, purpose: selected ? null : p.value }))}
              />
            );
          })}
        </ScrollView>
      </View>
    </View>
  );

  const renderEmpty = () => {
    if (loading) {
      return (
        <View style={{ gap: space.xl }}>
          {[0, 1].map((i) => (
            <View key={i} style={{ gap: space.sm }}>
              <Skeleton height={220} />
              <Skeleton height={14} width="40%" />
              <Skeleton height={20} width="70%" />
            </View>
          ))}
        </View>
      );
    }
    if (error) return <ErrorState message={friendlyError(error)} onRetry={first.reload} />;
    const filtered = filters.type || filters.city || filters.start || filters.purpose || filters.near;
    return (
      <EmptyState
        icon="search-outline"
        title={filtered ? 'No encontramos nada con esos filtros' : 'Todavía no hay vehículos publicados'}
        body={
          filtered
            ? filters.near
              ? 'No hay vehículos con punto de entrega en ese radio. Prueba con un radio mayor o busca por comuna.'
              : 'Prueba con otras fechas, otra comuna u otro tipo de vehículo.'
            : '¿Tienes algo parado? Publícalo en "Mis vehículos" y hazlo producir.'
        }
      />
    );
  };

  return (
    <SafeAreaView style={styles.safe} edges={['top']}>
      <FlatList
        data={loading || error ? [] : items}
        keyExtractor={(v) => v.id}
        renderItem={({ item }) => <VehicleCard v={item} onPress={() => openVehicle(item.id)} />}
        ItemSeparatorComponent={() => <View style={{ height: space.xl }} />}
        ListHeaderComponent={header}
        ListEmptyComponent={renderEmpty}
        ListFooterComponent={loadingMore ? <Skeleton height={220} style={{ marginTop: space.xl }} /> : null}
        contentContainerStyle={{ paddingHorizontal: gutter, paddingBottom: space.xxxl }}
        keyboardShouldPersistTaps="handled"
        onEndReached={loadMore}
        onEndReachedThreshold={0.5}
        initialNumToRender={4}
        windowSize={7}
        removeClippedSubviews
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={colors.accent} />
        }
      />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: colors.background },
  topBar: { paddingTop: space.md, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  unreadDot: {
    position: 'absolute',
    top: 0,
    right: 0,
    width: 9,
    height: 9,
    borderRadius: 5,
    backgroundColor: colors.accent,
    borderWidth: 1.5,
    borderColor: colors.background,
  },
});
