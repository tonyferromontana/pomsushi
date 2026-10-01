import { useState } from 'react';
import { View } from 'react-native';

import { DateField } from '@/components/DateRangeField';
import { Badge, Button, Card, Notice, Row, Text } from '@/components/ui';
import { friendlyError, logError } from '@/lib/errors';
import { addDays, clp, fromISODate, plural, shortDate } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import type { Booking, BookingExtension, ExtensionStatus } from '@/lib/types';
import { space } from '@/theme';

const STATUS: Record<ExtensionStatus, { label: string; tone: 'info' | 'success' | 'warning' | 'error' }> = {
  pending_owner: { label: 'Esperando al propietario', tone: 'info' },
  awaiting_payment: { label: 'Falta pagar', tone: 'warning' },
  paid: { label: 'Pagada', tone: 'success' },
  rejected: { label: 'Rechazada', tone: 'error' },
  expired: { label: 'Vencida', tone: 'warning' },
  cancelled: { label: 'Cancelada', tone: 'warning' },
};

/**
 * Extender el arriendo: el servidor verifica disponibilidad, calcula precio y cargo, pide aprobación
 * al propietario y, con el pago confirmado por Webpay, mueve la fecha de devolución.
 */
export function ExtensionCard({
  booking,
  extensions,
  role,
  onChanged,
  onPay,
  paying,
}: {
  booking: Booking;
  extensions: BookingExtension[];
  role: 'owner' | 'renter';
  onChanged: () => Promise<void>;
  onPay: (extensionId: string) => void;
  paying: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [newEnd, setNewEnd] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const active = booking.status === 'confirmada' || booking.status === 'en_curso';
  const current = extensions.find((e) => e.status === 'pending_owner' || e.status === 'awaiting_payment');
  if (!active && extensions.length === 0) return null;

  const call = async (fn: () => PromiseLike<{ error: unknown }>, ctx: string) => {
    setBusy(true);
    setError(null);
    try {
      const { error: err } = await fn();
      if (err) throw err;
      setOpen(false);
      setNewEnd(null);
      await onChanged();
    } catch (e) {
      logError(ctx, e);
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card style={{ gap: space.md }}>
      <Text variant="h3">Extender el arriendo</Text>
      {extensions.map((e) => (
        <View key={e.id} style={{ gap: space.xs }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: space.sm }}>
            <Text variant="bodySmall" style={{ flex: 1 }}>
              Hasta el {shortDate(e.new_end_date)} · {plural(e.days, 'día', 'días')} más
            </Text>
            <Badge label={STATUS[e.status].label} tone={STATUS[e.status].tone} />
          </View>
          {role === 'renter' ? (
            <Row label={`${plural(e.days, 'día', 'días')} + cargo de servicio`} value={clp(e.total_clp)} />
          ) : (
            <Row label="Recibes por la extensión" value={clp(e.owner_payout_clp)} />
          )}
        </View>
      ))}

      {current && role === 'owner' && current.status === 'pending_owner' ? (
        <View style={{ gap: space.sm }}>
          <Button
            label="Aprobar extensión"
            loading={busy}
            onPress={() => call(() => supabase.rpc('respond_extension', { p_extension_id: current.id, p_approve: true }), 'respond_extension')}
          />
          <Button
            label="Rechazar"
            variant="danger"
            disabled={busy}
            onPress={() => call(() => supabase.rpc('respond_extension', { p_extension_id: current.id, p_approve: false }), 'respond_extension')}
          />
        </View>
      ) : null}

      {current && role === 'renter' ? (
        <View style={{ gap: space.sm }}>
          {current.status === 'awaiting_payment' ? (
            <Button label={`Pagar extensión ${clp(current.total_clp)}`} icon="card-outline" loading={paying} onPress={() => onPay(current.id)} />
          ) : (
            <Notice>Le avisamos al propietario. Si la aprueba, podrás pagarla aquí.</Notice>
          )}
          <Button
            label="Cancelar extensión"
            variant="ghost"
            disabled={busy || paying}
            onPress={() => call(() => supabase.rpc('cancel_extension', { p_extension_id: current.id }), 'cancel_extension')}
          />
        </View>
      ) : null}

      {active && !current && role === 'renter' ? (
        open ? (
          <View style={{ gap: space.sm }}>
            <DateField
              label="Nueva fecha de devolución"
              value={newEnd}
              onChange={setNewEnd}
              minimumDate={addDays(fromISODate(booking.end_date), 1)}
            />
            <Text variant="caption" color="textSecondary">
              Se mantiene la tarifa diaria de tu reserva. El propietario debe aprobarla y luego la pagas con Webpay.
            </Text>
            <Button
              label="Pedir extensión"
              loading={busy}
              disabled={!newEnd}
              onPress={() => call(() => supabase.rpc('request_extension', { p_booking_id: booking.id, p_new_end: newEnd }), 'request_extension')}
            />
            <Button label="Volver" variant="ghost" onPress={() => setOpen(false)} />
          </View>
        ) : (
          <Button label="Necesito más días" variant="secondary" icon="calendar-outline" onPress={() => setOpen(true)} />
        )
      ) : null}

      {error ? <Notice tone="error">{error}</Notice> : null}
    </Card>
  );
}
