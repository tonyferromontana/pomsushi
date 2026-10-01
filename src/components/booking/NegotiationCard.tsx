import { useState } from 'react';
import { View } from 'react-native';

import { TimeField } from '@/components/DateRangeField';
import { Badge, Button, Card, Input, Notice, Text } from '@/components/ui';
import { friendlyError, logError } from '@/lib/errors';
import { clp, shortDate, thousands, toInt } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import type { Booking, BookingOffer, OfferStatus } from '@/lib/types';
import { space } from '@/theme';

const STATUS_LABEL: Record<OfferStatus, { label: string; tone: 'info' | 'success' | 'warning' | 'error' }> = {
  pending: { label: 'Esperando respuesta', tone: 'info' },
  accepted: { label: 'Aceptada', tone: 'success' },
  rejected: { label: 'Rechazada', tone: 'error' },
  countered: { label: 'Contraofertada', tone: 'warning' },
  expired: { label: 'Vencida', tone: 'warning' },
  cancelled: { label: 'Cerrada', tone: 'warning' },
};

/**
 * Negociación de precio por día (tipo inDrive). La app solo muestra y envía la intención:
 * el servidor valida mínimo, rondas, disponibilidad y estado (counter_offer / accept_offer / accept_booking).
 */
export function NegotiationCard({
  booking,
  offers,
  role,
  onChanged,
  onOwnerAccept,
}: {
  booking: Booking;
  offers: BookingOffer[];
  role: 'owner' | 'renter';
  onChanged: () => Promise<void>;
  /** El propietario acepta con horas (abre la tarjeta de horas del detalle). */
  onOwnerAccept: () => void;
}) {
  const [counterOpen, setCounterOpen] = useState(false);
  const [amount, setAmount] = useState('');
  const [pickup, setPickup] = useState('10:00');
  const [ret, setRet] = useState('10:00');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (offers.length === 0) return null;
  const myId = role === 'owner' ? booking.owner_id : booking.renter_id;
  const pending = booking.status === 'solicitada' ? offers.find((o) => o.status === 'pending') : undefined;
  const myTurn = !!pending && pending.recipient_id === myId;
  const canCounter = myTurn && pending.round_number < pending.max_rounds;
  const who = (o: BookingOffer) => (o.sender_id === myId ? 'Tú' : role === 'owner' ? 'Arrendatario' : 'Propietario');

  const run = async (fn: () => PromiseLike<{ error: unknown }>, ctx: string) => {
    setBusy(true);
    setError(null);
    try {
      const { error: err } = await fn();
      if (err) throw err;
      setCounterOpen(false);
      setAmount('');
      await onChanged();
    } catch (e) {
      logError(ctx, e);
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  };

  const counter = () =>
    run(
      () =>
        supabase.rpc('counter_offer', {
          p_booking_id: booking.id,
          p_amount_clp: toInt(amount),
          p_pickup_time: role === 'owner' ? pickup : null,
          p_return_time: role === 'owner' ? ret : null,
        }),
      'counter_offer',
    );

  return (
    <Card style={{ gap: space.md }}>
      <Text variant="h3">Negociación de precio</Text>
      {offers.map((o) => (
        <View key={o.id} style={{ flexDirection: 'row', alignItems: 'center', gap: space.sm }}>
          <View style={{ flex: 1 }}>
            <Text variant="bodySmall">
              {who(o)} · {clp(o.amount_clp)} por día
              {o.pickup_time && o.return_time ? ` · entrega ${o.pickup_time.slice(0, 5)}, devolución ${o.return_time.slice(0, 5)}` : ''}
            </Text>
            <Text variant="caption" color="textSecondary">
              Ronda {o.round_number} de {o.max_rounds}
              {o.status === 'pending' ? ` · vence el ${shortDate(new Date(o.expires_at))}` : ''}
            </Text>
          </View>
          <Badge label={STATUS_LABEL[o.status].label} tone={STATUS_LABEL[o.status].tone} />
        </View>
      ))}

      {pending && !myTurn ? (
        <Notice>Esperando la respuesta de la otra parte. Si no responde a tiempo, la solicitud vence sin cobro.</Notice>
      ) : null}

      {myTurn ? (
        <View style={{ gap: space.sm }}>
          {role === 'renter' ? (
            <Button
              label={`Aceptar ${clp(pending.amount_clp)} por día`}
              loading={busy && !counterOpen}
              onPress={() => run(() => supabase.rpc('accept_offer', { p_booking_id: booking.id }), 'accept_offer')}
            />
          ) : (
            <Button label={`Aceptar ${clp(pending.amount_clp)} por día`} onPress={onOwnerAccept} />
          )}
          {canCounter && !counterOpen ? (
            <Button label="Hacer una contraoferta" variant="secondary" onPress={() => setCounterOpen(true)} />
          ) : null}
          {!canCounter ? (
            <Text variant="caption" color="textSecondary">
              Es la última ronda: solo puedes aceptar o {role === 'owner' ? 'rechazar' : 'cancelar'}.
            </Text>
          ) : null}
        </View>
      ) : null}

      {counterOpen ? (
        <View style={{ gap: space.sm }}>
          <Input
            label="Tu contraoferta por día (CLP)"
            keyboardType="number-pad"
            value={amount}
            onChangeText={(t) => setAmount(thousands(t))}
          />
          {role === 'owner' ? (
            <View style={{ flexDirection: 'row', gap: space.md }}>
              <TimeField label="Hora de entrega" value={pickup} onChange={setPickup} />
              <TimeField label="Hora de devolución" value={ret} onChange={setRet} />
            </View>
          ) : null}
          <Text variant="caption" color="textSecondary">
            {role === 'owner'
              ? 'Si el arrendatario acepta, la reserva queda aceptada con estas horas y lista para pagar.'
              : 'Si el propietario acepta, te propondrá las horas y podrás pagar.'}
          </Text>
          <Button label="Enviar contraoferta" onPress={counter} loading={busy} disabled={!toInt(amount)} />
          <Button label="Volver" variant="ghost" onPress={() => setCounterOpen(false)} />
        </View>
      ) : null}

      {error ? <Notice tone="error">{error}</Notice> : null}
    </Card>
  );
}
