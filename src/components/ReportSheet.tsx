import { useState } from 'react';
import { Modal, Pressable, StyleSheet, View } from 'react-native';

import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { colors, radius, space } from '@/theme';
import { Button, Chip, Input, Notice, Text } from './ui';

const REASONS = [
  { value: 'fraude', label: 'Fraude o estafa' },
  { value: 'vehiculo_no_corresponde', label: 'El vehículo no corresponde' },
  { value: 'acoso', label: 'Acoso o malos tratos' },
  { value: 'contenido_inapropiado', label: 'Contenido inapropiado' },
  { value: 'seguridad', label: 'Riesgo de seguridad' },
  { value: 'otro', label: 'Otro' },
] as const;

type Target = { userId?: string; vehicleId?: string; bookingId?: string };

/** Hoja para reportar un usuario, una publicación o una reserva (y opcionalmente bloquear). */
export function ReportSheet({
  visible,
  onClose,
  target,
  title = 'Reportar',
}: {
  visible: boolean;
  onClose: () => void;
  target: Target;
  title?: string;
}) {
  const { userId } = useAuth();
  const [reason, setReason] = useState<(typeof REASONS)[number]['value'] | null>(null);
  const [details, setDetails] = useState('');
  const [block, setBlock] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const close = () => {
    setReason(null);
    setDetails('');
    setBlock(false);
    setError(null);
    setDone(false);
    onClose();
  };

  const send = async () => {
    if (!reason || !userId) return;
    setSending(true);
    setError(null);
    try {
      const { error: err } = await supabase.from('reports').insert({
        reporter_id: userId,
        target_user_id: target.userId ?? null,
        target_vehicle_id: target.vehicleId ?? null,
        booking_id: target.bookingId ?? null,
        reason,
        details: details.trim() || null,
      });
      if (err) throw err;
      if (block && target.userId && target.userId !== userId) {
        const { error: bErr } = await supabase
          .from('user_blocks')
          .insert({ blocker_id: userId, blocked_id: target.userId });
        // 23505 = ya estaba bloqueado
        if (bErr && bErr.code !== '23505') throw bErr;
      }
      setDone(true);
    } catch (e) {
      logError('report', e);
      setError(friendlyError(e));
    } finally {
      setSending(false);
    }
  };

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={close}>
      <Pressable style={styles.backdrop} onPress={close}>
        <Pressable style={styles.sheet} onPress={() => undefined}>
          {done ? (
            <View style={{ gap: space.lg }}>
              <Text variant="h2">Gracias por avisarnos</Text>
              <Text color="textSecondary">
                Revisaremos tu reporte. {block ? 'Ya no verás a esta persona ni podrá escribirte.' : ''}
              </Text>
              <Button label="Listo" onPress={close} />
            </View>
          ) : (
            <View style={{ gap: space.lg }}>
              <Text variant="h2">{title}</Text>
              <View style={styles.wrap}>
                {REASONS.map((r) => (
                  <Chip key={r.value} label={r.label} selected={reason === r.value} onPress={() => setReason(r.value)} />
                ))}
              </View>
              <Input
                placeholder="Cuéntanos qué pasó (opcional)"
                value={details}
                onChangeText={setDetails}
                multiline
                maxLength={1000}
              />
              {target.userId && target.userId !== userId ? (
                <Chip label="Bloquear también a esta persona" selected={block} onPress={() => setBlock(!block)} />
              ) : null}
              {error ? <Notice tone="error">{error}</Notice> : null}
              <Button label="Enviar reporte" onPress={send} loading={sending} disabled={!reason} />
              <Button label="Cancelar" variant="ghost" onPress={close} />
            </View>
          )}
        </Pressable>
      </Pressable>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: colors.overlay, justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: colors.surface,
    borderTopLeftRadius: radius.xl,
    borderTopRightRadius: radius.xl,
    padding: space.xl,
    paddingBottom: space.xxxl,
  },
  wrap: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
});
