import * as Linking from 'expo-linking';
import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import * as WebBrowser from 'expo-web-browser';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Image } from 'expo-image';
import { Alert, RefreshControl, ScrollView, StyleSheet, View } from 'react-native';

import { TimeField } from '@/components/DateRangeField';
import { Stars } from '@/components/forms';
import { ReportSheet } from '@/components/ReportSheet';
import {
  Avatar,
  Badge,
  Button,
  Card,
  Divider,
  ErrorState,
  Input,
  LoadingState,
  Notice,
  Row,
  Screen,
  SectionHeader,
  Text,
} from '@/components/ui';
import { track } from '@/lib/analytics';
import { useAuth } from '@/lib/auth';
import { BOOKING_FLOW, BOOKING_STATUS, purposeLabel } from '@/lib/catalog';
import { friendlyError, logError } from '@/lib/errors';
import { clp, dateRange, plural, shortDate } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import type { Booking, BookingEvent, BookingStatus, Handover, Profile } from '@/lib/types';
import { useAsync } from '@/lib/useAsync';
import { colors, radius, space } from '@/theme';

type Detail = {
  booking: Booking;
  vehicleTitle: string;
  other: Profile | null;
  events: BookingEvent[];
  reviewed: boolean;
  paymentPending: boolean;
  handovers: (Handover & { photoUrls: string[] })[];
};

async function loadDetail(id: string, userId: string): Promise<Detail> {
  const { data, error } = await supabase.from('bookings').select('*').eq('id', id).single();
  if (error) throw error;
  const booking = data as Booking;
  const otherId = booking.owner_id === userId ? booking.renter_id : booking.owner_id;
  const [other, events, vehicle, review, payments] = await Promise.all([
    supabase.from('profiles').select('*').eq('id', otherId).maybeSingle(),
    supabase.from('booking_events').select('*').eq('booking_id', id).order('created_at'),
    supabase.rpc('booking_vehicle', { p_booking_id: id }),
    supabase.from('reviews').select('id').eq('booking_id', id).eq('author_id', userId).maybeSingle(),
    supabase.from('payments').select('status').eq('booking_id', id).in('status', ['pending', 'in_process']),
  ]);
  const handoverRes = await supabase.from('booking_handovers').select('*').eq('booking_id', id).order('created_at');
  if (handoverRes.error) logError('booking.handovers', handoverRes.error);
  const rawHandovers = (handoverRes.data ?? []) as Handover[];
  // Fotos privadas: links firmados que expiran en 1 hora
  const allPaths = rawHandovers.flatMap((h) => h.photo_paths);
  let signed: Record<string, string> = {};
  if (allPaths.length > 0) {
    const res = await supabase.storage.from('handovers').createSignedUrls(allPaths, 3600);
    if (res.error) logError('booking.handoverPhotos', res.error);
    signed = Object.fromEntries((res.data ?? []).filter((r) => r.signedUrl).map((r) => [r.path, r.signedUrl]));
  }
  const handovers = rawHandovers.map((h) => ({ ...h, photoUrls: h.photo_paths.map((p) => signed[p]).filter(Boolean) }));
  if (events.error) throw events.error;
  if (other.error) logError('booking.other', other.error);
  if (vehicle.error) logError('booking.vehicle', vehicle.error);
  if (review.error) logError('booking.review', review.error);
  if (payments.error) logError('booking.payments', payments.error);
  const v = (vehicle.data as { title: string }[] | null)?.[0];
  return {
    booking,
    vehicleTitle: v?.title ?? 'Vehículo',
    other: (other.data as Profile) ?? null,
    events: (events.data ?? []) as BookingEvent[],
    reviewed: !!review.data,
    paymentPending: (payments.data ?? []).length > 0,
    handovers,
  };
}

type Action = {
  to: BookingStatus;
  label: string;
  variant?: 'primary' | 'secondary' | 'danger';
  confirm?: string;
};

/** Acciones que la app ofrece. El servidor igual valida cada una (transition_booking). */
function actionsFor(role: 'owner' | 'renter', status: BookingStatus): Action[] {
  if (role === 'owner') {
    switch (status) {
      case 'solicitada':
        return [
          { to: 'aceptada', label: 'Aceptar solicitud' },
          { to: 'rechazada', label: 'Rechazar', variant: 'danger', confirm: '¿Seguro que quieres rechazar esta solicitud?' },
        ];
      case 'aceptada':
        return [{ to: 'cancelada', label: 'Cancelar', variant: 'danger', confirm: '¿Cancelar esta reserva? El arrendatario todavía no ha pagado.' }];
      case 'confirmada':
        return [{ to: 'en_curso', label: 'Marcar como entregado', confirm: '¿Ya entregaste el vehículo?' }];
      case 'en_curso':
        return [
          { to: 'devuelta', label: 'Marcar como devuelto', confirm: '¿Ya te devolvieron el vehículo?' },
          { to: 'disputada', label: 'Reportar un problema', variant: 'danger', confirm: 'Vamos a revisar la reserva. ¿Quieres reportar un problema?' },
        ];
      case 'devuelta':
        return [
          { to: 'finalizada', label: 'Todo en orden, finalizar' },
          { to: 'disputada', label: 'Reportar un problema', variant: 'danger', confirm: 'Vamos a revisar la reserva. ¿Quieres reportar un problema?' },
        ];
      default:
        return [];
    }
  }
  switch (status) {
    case 'solicitada':
      return [{ to: 'cancelada', label: 'Cancelar solicitud', variant: 'danger', confirm: '¿Cancelar tu solicitud?' }];
    case 'aceptada':
      return [{ to: 'cancelada', label: 'Cancelar', variant: 'danger', confirm: '¿Cancelar esta reserva?' }];
    case 'en_curso':
    case 'devuelta':
      return [{ to: 'disputada', label: 'Reportar un problema', variant: 'danger', confirm: 'Vamos a revisar la reserva. ¿Quieres reportar un problema?' }];
    default:
      return [];
  }
}

function nextStepText(role: 'owner' | 'renter', b: Booking): string | null {
  const until = b.expires_at ? ` antes del ${shortDate(new Date(b.expires_at))}` : '';
  switch (b.status) {
    case 'solicitada':
      return role === 'owner'
        ? `Tienes una solicitud nueva. Respóndela${until}.`
        : `Esperando que el propietario responda${until}. No se cobra nada todavía.`;
    case 'aceptada':
      return role === 'owner'
        ? 'Aceptaste. Falta que el arrendatario pague para confirmar.'
        : `¡Te aceptaron! Paga${until} para confirmar tu reserva.`;
    case 'confirmada':
      return role === 'owner'
        ? `Reserva pagada. Entrega el vehículo el ${shortDate(b.start_date)}.`
        : `Reserva confirmada. Retiras el ${shortDate(b.start_date)}.`;
    case 'en_curso':
      return `Devolución el ${shortDate(b.end_date)}.`;
    case 'devuelta':
      return role === 'owner' ? 'Revisa el vehículo y finaliza la reserva.' : 'El propietario está revisando el vehículo.';
    case 'disputada':
      return 'Estamos revisando esta reserva. Te contactaremos.';
    default:
      return null;
  }
}

export default function BookingScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const { data, error, loading, reload } = useAsync(() => loadDetail(id, userId as string), [id, userId], !!userId);

  // Al volver de completar un acta, se recarga (no en la primera visita).
  const focusedOnce = useRef(false);
  useFocusEffect(
    useCallback(() => {
      if (focusedOnce.current) void reload();
      focusedOnce.current = true;
    }, [reload]),
  );
  const [busy, setBusy] = useState<BookingStatus | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [paying, setPaying] = useState(false);
  const [payNotice, setPayNotice] = useState<string | null>(null);
  const [rating, setRating] = useState(0);
  const [comment, setComment] = useState('');
  const [sendingReview, setSendingReview] = useState(false);
  const [reviewError, setReviewError] = useState<string | null>(null);
  const [reportOpen, setReportOpen] = useState(false);
  const [acceptOpen, setAcceptOpen] = useState(false);
  const [pickupTime, setPickupTime] = useState('10:00');
  const [returnTime, setReturnTime] = useState('10:00');

  // Si la otra parte cambia el estado, se actualiza solo.
  useEffect(() => {
    const channel = supabase
      .channel(`booking-${id}`)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'bookings', filter: `id=eq.${id}` }, () => {
        void reload();
      })
      .subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [id, reload]);

  if (loading && !data) return <LoadingState />;
  if (error || !data) {
    return (
      <Screen>
        <ErrorState message={friendlyError(error, 'No encontramos esta reserva.')} onRetry={reload} />
      </Screen>
    );
  }

  const { booking: b, other, events, vehicleTitle } = data;
  const role: 'owner' | 'renter' = b.owner_id === userId ? 'owner' : 'renter';
  const status = BOOKING_STATUS[b.status];
  const actions = actionsFor(role, b.status);
  const step = nextStepText(role, b);
  const flowIndex = BOOKING_FLOW.indexOf(b.status);

  // Pago: el servidor crea el link de Mercado Pago con el monto de la reserva.
  // Volver a la app NO confirma nada: la confirmación llega por el webhook y se ve en tiempo real.
  const pay = async () => {
    setPaying(true);
    setActionError(null);
    setPayNotice(null);
    try {
      track('checkout_started', { total: b.total_clp });
      const redirectUrl = Linking.createURL('pago');
      const { data: res, error: err } = await supabase.functions.invoke('mp-create-preference', {
        body: { booking_id: b.id, redirect_url: redirectUrl },
      });
      if (err) {
        const ctx = (err as { context?: Response }).context;
        const body = ctx ? ((await ctx.json().catch(() => null)) as { error?: string } | null) : null;
        throw new Error(body?.error ?? 'No pudimos abrir el pago. Inténtalo de nuevo.');
      }
      const url = (res as { checkout_url?: string }).checkout_url;
      if (!url) throw new Error('No pudimos abrir el pago. Inténtalo de nuevo.');
      const result = await WebBrowser.openAuthSessionAsync(url, redirectUrl);
      if (result.type === 'success') {
        const status = Linking.parse(result.url).queryParams?.status;
        setPayNotice(
          status === 'approved'
            ? 'Pago recibido. Estamos confirmando tu reserva…'
            : status === 'pending' || status === 'in_process'
              ? 'Tu pago está pendiente. Te avisaremos cuando se apruebe.'
              : 'El pago no se completó. Puedes intentarlo de nuevo.',
        );
      }
      await reload();
    } catch (e) {
      logError('pay', e);
      setActionError(e instanceof Error ? e.message : friendlyError(e));
    } finally {
      setPaying(false);
    }
  };

  const sendReview = async () => {
    if (rating < 1) return;
    setSendingReview(true);
    setReviewError(null);
    try {
      const { error: err } = await supabase.rpc('submit_review', {
        p_booking_id: b.id,
        p_rating: rating,
        p_comment: comment.trim() || null,
      });
      if (err) throw err;
      await reload();
    } catch (e) {
      logError('review', e);
      setReviewError(friendlyError(e));
    } finally {
      setSendingReview(false);
    }
  };

  const hhmm = (t: string | null) => (t ? t.slice(0, 5) : null);

  // Aceptar: el propietario propone la hora de entrega y de devolución.
  const accept = async () => {
    setBusy('aceptada');
    setActionError(null);
    try {
      const { error: err } = await supabase.rpc('accept_booking', {
        p_booking_id: b.id,
        p_pickup_time: pickupTime,
        p_return_time: returnTime,
      });
      if (err) throw err;
      track('booking_accepted');
      setAcceptOpen(false);
      await reload();
    } catch (e) {
      logError('accept_booking', e);
      setActionError(friendlyError(e));
    } finally {
      setBusy(null);
    }
  };

  const run = async (a: Action) => {
    if (a.to === 'aceptada') {
      setAcceptOpen(true);
      return;
    }
    const go = async () => {
      setBusy(a.to);
      setActionError(null);
      try {
        const { error: err } = await supabase.rpc('transition_booking', { p_booking_id: b.id, p_to: a.to });
        if (err) throw err;
        if (a.to === 'aceptada') track('booking_accepted');
        await reload();
      } catch (e) {
        logError('transition_booking', e);
        setActionError(friendlyError(e));
      } finally {
        setBusy(null);
      }
    };
    if (a.confirm) {
      Alert.alert(a.label, a.confirm, [
        { text: 'Volver', style: 'cancel' },
        { text: 'Sí, continuar', style: a.variant === 'danger' ? 'destructive' : 'default', onPress: go },
      ]);
    } else {
      await go();
    }
  };

  return (
    <Screen
      scroll
      edges={['bottom']}
      refreshControl={<RefreshControl refreshing={loading} onRefresh={reload} tintColor={colors.accent} />}
    >
      <View style={{ gap: space.md, paddingTop: space.lg }}>
        <Badge label={status.label} tone={status.tone} />
        <Text variant="h1">{vehicleTitle}</Text>
        <Text color="textSecondary">
          {dateRange(b.start_date, b.end_date)} · {plural(b.days, 'día', 'días')}
          {b.pickup_time && b.return_time ? ` · entrega ${hhmm(b.pickup_time)}, devolución ${hhmm(b.return_time)}` : ''}
          {b.purpose ? ` · ${purposeLabel(b.purpose)}` : ''}
        </Text>
        {step ? <Notice tone={status.tone}>{step}</Notice> : null}
      </View>

      {flowIndex >= 0 ? (
        <View style={styles.flow} accessibilityLabel={`Paso ${flowIndex + 1} de ${BOOKING_FLOW.length}`}>
          {BOOKING_FLOW.map((s, i) => (
            <View key={s} style={[styles.flowStep, { backgroundColor: i <= flowIndex ? colors.accent : colors.border }]} />
          ))}
        </View>
      ) : null}

      {role === 'renter' && b.status === 'aceptada' ? (
        <View style={{ gap: space.sm, marginTop: space.xl }}>
          <Button label={`Pagar ${clp(b.total_clp)}`} icon="card-outline" onPress={pay} loading={paying} />
          {payNotice || data.paymentPending ? (
            <Notice tone="info">{payNotice ?? 'Tienes un pago pendiente de aprobación. Te avisaremos apenas se confirme.'}</Notice>
          ) : null}
          <Text variant="caption" color="textSecondary" align="center">
            Pago seguro con Mercado Pago. RUÉ no guarda los datos de tu tarjeta.
          </Text>
        </View>
      ) : null}

      {b.status === 'finalizada' ? (
        <View style={{ gap: space.md, marginTop: space.xl }}>
          <SectionHeader title={role === 'owner' ? '¿Cómo fue el arrendatario?' : '¿Cómo te fue?'} />
          {data.reviewed ? (
            <Notice tone="success">Gracias por dejar tu reseña.</Notice>
          ) : (
            <>
              <Stars value={rating} onChange={setRating} />
              <Input placeholder="Cuéntale a la comunidad (opcional)" value={comment} onChangeText={setComment} multiline maxLength={800} />
              {reviewError ? <Notice tone="error">{reviewError}</Notice> : null}
              <Button label="Enviar reseña" onPress={sendReview} loading={sendingReview} disabled={rating < 1} />
            </>
          )}
        </View>
      ) : null}

      {actions.length > 0 ? (
        <View style={{ gap: space.sm, marginTop: space.xl }}>
          {actions.map((a) => (
            <Button
              key={a.to}
              label={a.label}
              variant={a.variant ?? 'primary'}
              loading={busy === a.to}
              disabled={busy !== null && busy !== a.to}
              onPress={() => run(a)}
            />
          ))}
          {actionError ? <Notice tone="error">{actionError}</Notice> : null}
        </View>
      ) : null}

      {acceptOpen ? (
        <Card style={{ gap: space.md, marginTop: space.xl }}>
          <Text variant="h3">¿A qué hora entregas y recibes el vehículo?</Text>
          <Text variant="bodySmall" color="textSecondary">
            El arrendatario verá estas horas antes de pagar. El precio se calcula por días completos.
          </Text>
          <Text variant="caption" color="textSecondary">
            Entrega el {shortDate(b.start_date)} · devolución el {shortDate(b.end_date)}
          </Text>
          <View style={{ flexDirection: 'row', gap: space.md }}>
            <TimeField label="Hora de entrega" value={pickupTime} onChange={setPickupTime} />
            <TimeField label="Hora de devolución" value={returnTime} onChange={setReturnTime} />
          </View>
          <Button label="Aceptar con estas horas" onPress={accept} loading={busy === 'aceptada'} />
          <Button label="Volver" variant="ghost" onPress={() => setAcceptOpen(false)} />
        </Card>
      ) : null}


      <SectionHeader title={role === 'owner' ? 'Arrendatario' : 'Propietario'} />
      <Card style={styles.personRow}>
        <Avatar name={other?.display_name || 'Usuario'} uri={other?.avatar_url} />
        <View style={{ flex: 1 }}>
          <Text variant="title">{other?.display_name || 'Usuario RUÉ'}</Text>
          <Text variant="caption" color="textSecondary">
            {other?.identity_verified ? 'Identidad verificada' : 'Identidad sin verificar'}
          </Text>
        </View>
        <Button
          label="Mensajes"
          variant="secondary"
          icon="chatbubble-outline"
          small
          onPress={() => router.push({ pathname: '/chat/[id]', params: { id: b.id } })}
        />
      </Card>

      {b.renter_message ? (
        <>
          <SectionHeader title="Mensaje de la solicitud" />
          <Text color="textSecondary">“{b.renter_message}”</Text>
        </>
      ) : null}

      <SectionHeader title="Detalle" />
      <View style={{ gap: space.xs }}>
        <Row label={`Arriendo · ${plural(b.days, 'día', 'días')}`} value={clp(b.rental_clp)} />
        {role === 'renter' ? (
          <>
            {b.renter_fee_clp > 0 ? <Row label="Cargo de servicio" value={clp(b.renter_fee_clp)} /> : null}
            <Divider spacing={space.sm} />
            <Row label="Total" value={clp(b.total_clp)} strong />
          </>
        ) : (
          <>
            {b.owner_commission_clp > 0 ? <Row label="Comisión RUÉ" value={`-${clp(b.owner_commission_clp)}`} /> : null}
            <Divider spacing={space.sm} />
            <Row label="Recibes" value={clp(b.owner_payout_clp)} strong />
          </>
        )}
        {b.deposit_clp > 0 ? <Row label="Garantía (se coordina con el propietario)" value={clp(b.deposit_clp)} /> : null}
      </View>

      {b.status === 'confirmada' || b.status === 'en_curso' || data.handovers.length > 0 ? (
        <>
          <SectionHeader title="Actas de entrega y devolución" />
          <View style={{ gap: space.md }}>
            {data.handovers.length === 0 ? (
              <Text variant="bodySmall" color="textSecondary">
                Al entregar el vehículo, completen juntos el acta con kilometraje, combustible y fotos.
              </Text>
            ) : null}
            {data.handovers.map((h) => (
              <Card key={h.id} style={{ gap: space.sm }}>
                <Text variant="title">
                  {h.kind === 'entrega' ? 'Entrega' : 'Devolución'} · {h.author_id === userId ? 'tú' : other?.display_name || 'la otra parte'}
                </Text>
                <Text variant="caption" color="textSecondary">
                  {shortDate(new Date(h.created_at))}
                  {h.odometer_km !== null ? ` · ${h.odometer_km.toLocaleString('es-CL')} km` : ''}
                  {h.fuel_level !== null ? ` · combustible ${h.fuel_level} %` : ''}
                </Text>
                {h.notes ? <Text variant="bodySmall">{h.notes}</Text> : null}
                {h.photoUrls.length > 0 ? (
                  <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: space.sm }}>
                    {h.photoUrls.map((u) => (
                      <Image key={u} source={{ uri: u }} style={styles.handoverPhoto} contentFit="cover" />
                    ))}
                  </ScrollView>
                ) : null}
              </Card>
            ))}
            {b.status === 'confirmada' || b.status === 'en_curso' ? (
              <Button
                label={b.status === 'confirmada' ? 'Completar acta de entrega' : 'Completar acta de devolución'}
                variant="secondary"
                icon="clipboard-outline"
                onPress={() =>
                  router.push({
                    pathname: '/handover',
                    params: { booking: b.id, kind: b.status === 'confirmada' ? 'entrega' : 'devolucion' },
                  })
                }
              />
            ) : null}
          </View>
        </>
      ) : null}

      <SectionHeader title="Historial" />
      <View style={{ gap: space.sm }}>
        {events.map((e) => (
          <View key={e.id} style={styles.event}>
            <View style={styles.eventDot} />
            <View style={{ flex: 1 }}>
              <Text variant="label">{BOOKING_STATUS[e.to_status].label}</Text>
              <Text variant="caption" color="textSecondary">
                {shortDate(new Date(e.created_at))}
                {e.note ? ` · ${e.note}` : ''}
              </Text>
            </View>
          </View>
        ))}
      </View>

      <View style={{ marginTop: space.xxl }}>
        <Button label="Reportar un problema" variant="ghost" icon="flag-outline" small onPress={() => setReportOpen(true)} />
      </View>
      <ReportSheet
        visible={reportOpen}
        onClose={() => setReportOpen(false)}
        target={{ userId: other?.id, bookingId: b.id }}
        title="Reportar esta reserva"
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  flow: { flexDirection: 'row', gap: space.xs, marginTop: space.xl },
  flowStep: { flex: 1, height: 4, borderRadius: 2 },
  personRow: { flexDirection: 'row', alignItems: 'center', gap: space.md },
  event: { flexDirection: 'row', gap: space.md, alignItems: 'flex-start' },
  handoverPhoto: { width: 96, height: 96, borderRadius: radius.md },
  eventDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.accent, marginTop: 6 },
});
