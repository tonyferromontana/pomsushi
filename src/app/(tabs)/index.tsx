import MaterialCommunityIcons from '@expo/vector-icons/MaterialCommunityIcons';
import { router } from 'expo-router';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { FlatList, RefreshControl, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { DateRangeField } from '@/components/DateRangeField';
import { Chip, EmptyState, ErrorState, Input, Skeleton, Text, Wordmark } from '@/components/ui';
import { VehicleCard } from '@/components/VehicleCard';
import { track } from '@/lib/analytics';
import { PURPOSES, VEHICLE_TYPES } from '@/lib/catalog';
import { friendlyError, logError } from '@/lib/errors';
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
};

async function fetchPage(f: Filters, offset: number): Promise<VehicleSearchResult[]> {
  const { data, error } = await supabase.rpc('search_vehicles', {
    p_type: f.type,
    p_city: f.city.trim() || null,
    p_start: f.start && f.end ? f.start : null,
    p_end: f.start && f.end ? f.end : null,
    p_purpose: f.purpose,
    p_limit: PAGE_SIZE,
    p_offset: offset,
  });
  if (error) throw error;
  return (data ?? []) as VehicleSearchResult[];
}

export default function ExploreScreen() {
  const [filters, setFilters] = useState<Filters>({ type: null, city: '', start: null, end: null, purpose: null });
  const [cityDraft, setCityDraft] = useState('');
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
      <View style={{ paddingTop: space.md }}>
        <Wordmark size={26} />
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
    const filtered = filters.type || filters.city || filters.start || filters.purpose;
    return (
      <EmptyState
        icon="search-outline"
        title={filtered ? 'No encontramos nada con esos filtros' : 'Todavía no hay vehículos publicados'}
        body={
          filtered
            ? 'Prueba con otras fechas, otra comuna u otro tipo de vehículo.'
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
});
