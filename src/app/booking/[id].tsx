import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { Alert, RefreshControl, StyleSheet, View } from 'react-native';

import {
  Avatar,
  Badge,
  Button,
  Card,
  Divider,
  ErrorState,
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
import type { Booking, BookingEvent, BookingStatus, Profile } from '@/lib/types';
import { useAsync } from '@/lib/useAsync';
import { colors, space } from '@/theme';

type Detail = {
  booking: Booking;
  vehicleTitle: string;
  other: Profile | null;
  events: BookingEvent[];
};

async function loadDetail(id: string, userId: string): Promise<Detail> {
  const { data, error } = await supabase
    .from('bookings')
    .select('*, vehicle:vehicles(title)')
    .eq('id', id)
    .single();
  if (error) throw error;
  const booking = data as Booking & { vehicle: { title: string } | null };
  const otherId = booking.owner_id === userId ? booking.renter_id : booking.owner_id;
  const [other, events] = await Promise.all([
    supabase.from('profiles').select('*').eq('id', otherId).maybeSingle(),
    supabase.from('booking_events').select('*').eq('booking_id', id).order('created_at'),
  ]);
  if (events.error) throw events.error;
  if (other.error) logError('booking.other', other.error);
  return {
    booking,
    vehicleTitle: booking.vehicle?.title ?? 'Vehículo',
    other: (other.data as Profile) ?? null,
    events: (events.data ?? []) as BookingEvent[],
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
  const [busy, setBusy] = useState<BookingStatus | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

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

  const run = async (a: Action) => {
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
          <Button label={`Pagar ${clp(b.total_clp)}`} icon="card-outline" disabled />
          <Text variant="caption" color="textSecondary" align="center">
            El pago con Mercado Pago se activa en la próxima etapa del desarrollo.
          </Text>
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
        {b.deposit_clp > 0 ? <Row label="Garantía" value={clp(b.deposit_clp)} /> : null}
      </View>

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
    </Screen>
  );
}

const styles = StyleSheet.create({
  flow: { flexDirection: 'row', gap: space.xs, marginTop: space.xl },
  flowStep: { flex: 1, height: 4, borderRadius: 2 },
  personRow: { flexDirection: 'row', alignItems: 'center', gap: space.md },
  event: { flexDirection: 'row', gap: space.md, alignItems: 'flex-start' },
  eventDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.accent, marginTop: 6 },
});
