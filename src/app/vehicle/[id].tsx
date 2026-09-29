import Ionicons from '@expo/vector-icons/Ionicons';
import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { FlatList, StyleSheet, useWindowDimensions, View } from 'react-native';

import { DateRangeField } from '@/components/DateRangeField';
import {
  Avatar,
  Badge,
  Button,
  Chip,
  Divider,
  ErrorState,
  Input,
  LoadingState,
  Notice,
  Price,
  Row,
  Screen,
  SectionHeader,
  Text,
} from '@/components/ui';
import { ReportSheet } from '@/components/ReportSheet';
import { VehiclePhoto } from '@/components/VehicleCard';
import { track } from '@/lib/analytics';
import { attributeSummary, PURPOSES, purposeLabel, vehicleTypeLabel } from '@/lib/catalog';
import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { clp, memberSince, plural } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import type { BookingPurpose, Profile, Quote, Vehicle, VehiclePhoto as Photo } from '@/lib/types';
import { useAsync } from '@/lib/useAsync';
import { colors, photoAspect, radius, space } from '@/theme';

type Reputation = { rating_avg: number | null; rating_count: number; completed_bookings: number };
type Detail = { vehicle: Vehicle; photos: Photo[]; owner: Profile | null; reputation: Reputation | null };

async function loadDetail(id: string): Promise<Detail> {
  const { data: vehicle, error } = await supabase.from('vehicles').select('*').eq('id', id).single();
  if (error) throw error;
  const [photos, owner, rep] = await Promise.all([
    supabase.from('vehicle_photos').select('*').eq('vehicle_id', id).order('position'),
    supabase.from('profiles').select('*').eq('id', vehicle.owner_id).maybeSingle(),
    supabase.rpc('user_reputation', { p_user_id: vehicle.owner_id }),
  ]);
  if (photos.error) throw photos.error;
  if (owner.error) logError('vehicle.owner', owner.error);
  if (rep.error) logError('vehicle.reputation', rep.error);
  return {
    vehicle: vehicle as Vehicle,
    photos: (photos.data ?? []) as Photo[],
    owner: (owner.data as Profile) ?? null,
    reputation: (rep.data as Reputation | null) ?? null,
  };
}

export default function VehicleScreen() {
  const params = useLocalSearchParams<{ id: string; start?: string; end?: string; purpose?: BookingPurpose }>();
  const { userId } = useAuth();
  const { width } = useWindowDimensions();
  const { data, error, loading, reload } = useAsync(() => loadDetail(params.id), [params.id]);

  const [start, setStart] = useState<string | null>(params.start ?? null);
  const [end, setEnd] = useState<string | null>(params.end ?? null);
  const [purpose, setPurpose] = useState<BookingPurpose | null>(params.purpose ?? null);
  const [message, setMessage] = useState('');
  const [quoteResult, setQuoteResult] = useState<{ key: string; quote: Quote | null; error: string | null } | null>(null);
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const [reportOpen, setReportOpen] = useState(false);
  const [photoIndex, setPhotoIndex] = useState(0);

  useEffect(() => {
    if (data) track('vehicle_view', { vehicle_type: data.vehicle.vehicle_type });
  }, [data]);

  // El precio lo calcula SIEMPRE el servidor. La cotización queda asociada a las fechas pedidas.
  const canQuote = !!start && !!end && !!data && data.vehicle.owner_id !== userId;
  const quoteKey = canQuote ? `${params.id}|${start}|${end}` : null;

  useEffect(() => {
    if (!quoteKey || !start || !end) return;
    let alive = true;
    supabase
      .rpc('quote_booking', { p_vehicle_id: params.id, p_start: start, p_end: end })
      .then(({ data: q, error: err }) => {
        if (!alive) return;
        if (err) {
          logError('quote_booking', err);
          setQuoteResult({ key: quoteKey, quote: null, error: friendlyError(err) });
        } else {
          setQuoteResult({ key: quoteKey, quote: q as Quote, error: null });
          track('booking_started', { days: (q as Quote).days });
        }
      });
    return () => {
      alive = false;
    };
  }, [quoteKey, start, end, params.id]);

  const currentQuote = quoteKey && quoteResult?.key === quoteKey ? quoteResult : null;
  const quote = currentQuote?.quote ?? null;
  const quoteError = currentQuote?.error ?? null;
  const quoting = !!quoteKey && !currentQuote;

  if (loading && !data) return <LoadingState />;
  if (error || !data) {
    return (
      <Screen>
        <ErrorState message={friendlyError(error, 'Este vehículo ya no está disponible.')} onRetry={reload} />
      </Screen>
    );
  }

  const { vehicle: v, photos, owner } = data;
  const isOwner = v.owner_id === userId;
  const specs = attributeSummary(v.attributes, v.vehicle_type);

  const request = async () => {
    if (!start || !end || !quote) return;
    setSending(true);
    setSendError(null);
    try {
      const { data: bookingId, error: err } = await supabase.rpc('request_booking', {
        p_vehicle_id: v.id,
        p_start: start,
        p_end: end,
        p_purpose: purpose,
        p_message: message.trim() || null,
      });
      if (err) throw err;
      track('booking_requested', { days: quote.days, vehicle_type: v.vehicle_type });
      router.replace({ pathname: '/booking/[id]', params: { id: bookingId as string } });
    } catch (e) {
      logError('request_booking', e);
      setSendError(friendlyError(e));
    } finally {
      setSending(false);
    }
  };

  const footer = isOwner ? (
    <Button
      label="Editar publicación"
      variant="secondary"
      icon="create-outline"
      onPress={() => router.push({ pathname: '/publish', params: { id: v.id } })}
    />
  ) : (
    <View style={styles.footerRow}>
      <View style={{ flex: 1 }}>
        {quote ? (
          <>
            <Price amount={quote.total_clp} />
            <Text variant="caption" color="textSecondary">
              {plural(quote.days, 'día', 'días')} · total
            </Text>
          </>
        ) : (
          <>
            <Price amount={v.daily_price_clp} suffix="/ día" />
            <Text variant="caption" color="textSecondary">
              Elige fechas para ver el total
            </Text>
          </>
        )}
      </View>
      <Button
        label="Solicitar"
        onPress={request}
        loading={sending}
        disabled={!quote || quoting}
        style={{ paddingHorizontal: space.xxl }}
      />
    </View>
  );

  return (
    <Screen scroll padded={false} edges={['bottom']} footer={footer}>
      <View>
        {photos.length > 0 ? (
          <FlatList
            data={photos}
            horizontal
            pagingEnabled
            showsHorizontalScrollIndicator={false}
            keyExtractor={(p) => p.id}
            onMomentumScrollEnd={(e) => setPhotoIndex(Math.round(e.nativeEvent.contentOffset.x / width))}
            renderItem={({ item }) => (
              <View style={{ width }}>
                <VehiclePhoto path={item.storage_path} vehicleType={v.vehicle_type} rounded={false} />
              </View>
            )}
          />
        ) : (
          <VehiclePhoto path={null} vehicleType={v.vehicle_type} rounded={false} aspect={photoAspect} />
        )}
        {photos.length > 1 ? (
          <View style={styles.counter}>
            <Text variant="caption">
              {photoIndex + 1} / {photos.length}
            </Text>
          </View>
        ) : null}
      </View>

      <View style={styles.content}>
        <View style={{ gap: space.xs }}>
          <Text variant="overline" color="textSecondary">
            {`${vehicleTypeLabel(v.vehicle_type)} · ${[v.comuna, v.city].filter(Boolean).join(', ')}`.toUpperCase()}
          </Text>
          <Text variant="h1">{v.title}</Text>
          <Text color="textSecondary">
            {v.brand} {v.model} {v.year}
          </Text>
          <View style={styles.badges}>
            {v.verified ? <Badge label="Vehículo verificado" tone="accent" /> : null}
            {v.status !== 'publicado' ? <Badge label={v.status === 'pausado' ? 'Pausado' : 'Borrador'} tone="warning" /> : null}
            {v.min_days > 1 ? <Badge label={`Mínimo ${v.min_days} días`} /> : null}
          </View>
        </View>

        {specs.length > 0 ? (
          <View style={styles.specs}>
            {specs.map((s) => (
              <View key={s} style={styles.spec}>
                <Text variant="label">{s}</Text>
              </View>
            ))}
          </View>
        ) : null}

        <View style={{ gap: space.xs }}>
          <Row label="Precio por día" value={clp(v.daily_price_clp)} />
          {v.weekly_price_clp ? <Row label="Precio por semana" value={clp(v.weekly_price_clp)} /> : null}
          {v.deposit_clp > 0 ? <Row label="Garantía (se coordina al retirar)" value={clp(v.deposit_clp)} /> : null}
        </View>

        {v.description ? (
          <>
            <SectionHeader title="Sobre este vehículo" />
            <Text color="textSecondary">{v.description}</Text>
          </>
        ) : null}

        {v.use_cases.length > 0 ? (
          <>
            <SectionHeader title="Ideal para" />
            <Text color="textSecondary">{v.use_cases.map(purposeLabel).join(' · ')}</Text>
          </>
        ) : null}

        {owner ? (
          <>
            <Divider spacing={space.xl} />
            <View style={styles.ownerRow}>
              <Avatar name={owner.display_name || 'Propietario'} uri={owner.avatar_url} />
              <View style={{ flex: 1 }}>
                <Text variant="title">{owner.display_name || 'Propietario RUÉ'}</Text>
                <Text variant="caption" color="textSecondary">
                  {data.reputation && data.reputation.rating_count > 0 && data.reputation.rating_avg !== null
                    ? `★ ${data.reputation.rating_avg} (${data.reputation.rating_count}) · `
                    : ''}
                  {data.reputation?.completed_bookings
                    ? `${plural(data.reputation.completed_bookings, 'arriendo', 'arriendos')} · `
                    : ''}
                  En RUÉ desde {memberSince(owner.created_at)}
                </Text>
              </View>
              {owner.identity_verified ? (
                <Ionicons name="shield-checkmark" size={20} color={colors.accent} accessibilityLabel="Identidad verificada" />
              ) : null}
            </View>
          </>
        ) : null}

        {!isOwner ? (
          <>
            <SectionHeader title="Tu reserva" />
            <View style={{ gap: space.lg }}>
              <DateRangeField
                start={start}
                end={end}
                onChange={(s, e) => {
                  setStart(s);
                  setEnd(e);
                }}
              />
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: space.sm }}>
                {PURPOSES.map((p) => (
                  <Chip
                    key={p.value}
                    label={p.label}
                    selected={purpose === p.value}
                    onPress={() => setPurpose(purpose === p.value ? null : p.value)}
                  />
                ))}
              </View>
              <Input
                label="Mensaje para el propietario (opcional)"
                placeholder="Cuéntale para qué lo necesitas"
                value={message}
                onChangeText={setMessage}
                multiline
                maxLength={1000}
              />

              {quoting ? <Text variant="bodySmall" color="textSecondary">Calculando…</Text> : null}
              {quoteError ? <Notice tone="warning">{quoteError}</Notice> : null}
              {quote ? (
                <View style={{ gap: space.xs }}>
                  <Row label={`Arriendo · ${plural(quote.days, 'día', 'días')}`} value={clp(quote.rental_clp)} />
                  {quote.renter_fee_clp > 0 ? <Row label="Cargo de servicio" value={clp(quote.renter_fee_clp)} /> : null}
                  <Divider spacing={space.sm} />
                  <Row label="Total" value={clp(quote.total_clp)} strong />
                  {quote.deposit_clp > 0 ? (
                    <Text variant="caption" color="textSecondary">
                      El propietario pide una garantía de {clp(quote.deposit_clp)} que se coordina al retirar y se devuelve si todo está en orden.
                    </Text>
                  ) : null}
                  <Text variant="caption" color="textSecondary">
                    No se cobra nada hasta que el propietario acepte.
                  </Text>
                </View>
              ) : null}
              {sendError ? <Notice tone="error">{sendError}</Notice> : null}
            </View>
          </>
        ) : (
          <View style={{ marginTop: space.xl }}>
            <Notice>Así ven tu publicación los arrendatarios.</Notice>
          </View>
        )}

        {!isOwner ? (
          <View style={{ marginTop: space.xl }}>
            <Button label="Reportar esta publicación" variant="ghost" icon="flag-outline" small onPress={() => setReportOpen(true)} />
          </View>
        ) : null}
      </View>
      <ReportSheet
        visible={reportOpen}
        onClose={() => setReportOpen(false)}
        target={{ userId: v.owner_id, vehicleId: v.id }}
        title="Reportar publicación"
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { paddingHorizontal: space.xl, paddingTop: space.xl, gap: space.lg },
  counter: {
    position: 'absolute',
    right: space.lg,
    bottom: space.lg,
    backgroundColor: colors.scrim,
    paddingHorizontal: space.sm,
    paddingVertical: space.xxs,
    borderRadius: radius.pill,
  },
  badges: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm, marginTop: space.xs },
  specs: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
  spec: {
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
  },
  ownerRow: { flexDirection: 'row', alignItems: 'center', gap: space.md },
  footerRow: { flexDirection: 'row', alignItems: 'center', gap: space.lg },
});
