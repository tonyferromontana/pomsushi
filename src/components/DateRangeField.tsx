import DateTimePicker, { DateTimePickerAndroid, type DateTimePickerEvent } from '@react-native-community/datetimepicker';
import { useState } from 'react';
import { Modal, Platform, Pressable, StyleSheet, View } from 'react-native';

import { addDays, fromISODate, shortDate, startOfToday, toISODate } from '@/lib/format';
import { colors, radius, space } from '@/theme';
import { Button, FieldButton, Text } from './ui';

type Props = {
  start: string | null;
  end: string | null;
  onChange: (start: string | null, end: string | null) => void;
};

/**
 * Selector de fechas de inicio y devolución.
 * Guarda fechas 'YYYY-MM-DD'. La devolución es exclusiva: 3→5 = 2 días.
 */
export function DateRangeField({ start, end, onChange }: Props) {
  const [iosPicking, setIosPicking] = useState<'start' | 'end' | null>(null);
  const [draft, setDraft] = useState<Date>(startOfToday());

  const minFor = (which: 'start' | 'end') =>
    which === 'start' ? startOfToday() : addDays(start ? fromISODate(start) : startOfToday(), 1);

  const apply = (which: 'start' | 'end', d: Date) => {
    const iso = toISODate(d);
    if (which === 'start') {
      // Si el término queda antes del inicio, se limpia
      const keepEnd = end && fromISODate(end) > d ? end : null;
      onChange(iso, keepEnd);
    } else {
      onChange(start, iso);
    }
  };

  const open = (which: 'start' | 'end') => {
    const current = which === 'start' ? start : end;
    const min = minFor(which);
    const value = current ? fromISODate(current) : min;

    if (Platform.OS === 'android') {
      DateTimePickerAndroid.open({
        value,
        mode: 'date',
        minimumDate: min,
        onChange: (event: DateTimePickerEvent, d?: Date) => {
          if (event.type === 'set' && d) apply(which, d);
        },
      });
      return;
    }
    setDraft(value);
    setIosPicking(which);
  };

  return (
    <View style={styles.row}>
      <FieldButton
        style={{ flex: 1 }}
        label="Desde"
        icon="calendar-outline"
        placeholder="Inicio"
        value={start ? shortDate(start) : null}
        onPress={() => open('start')}
      />
      <FieldButton
        style={{ flex: 1 }}
        label="Hasta"
        icon="calendar-outline"
        placeholder="Devolución"
        value={end ? shortDate(end) : null}
        onPress={() => open('end')}
      />

      {Platform.OS === 'ios' ? (
        <Modal visible={iosPicking !== null} transparent animationType="fade" onRequestClose={() => setIosPicking(null)}>
          <Pressable style={styles.backdrop} onPress={() => setIosPicking(null)}>
            <Pressable style={styles.sheet} onPress={() => undefined}>
              <Text variant="h3">{iosPicking === 'start' ? '¿Desde cuándo?' : '¿Hasta cuándo?'}</Text>
              {iosPicking ? (
                <DateTimePicker
                  value={draft}
                  mode="date"
                  display="inline"
                  themeVariant="dark"
                  accentColor={colors.accent}
                  locale="es-CL"
                  minimumDate={minFor(iosPicking)}
                  onChange={(_e, d) => d && setDraft(d)}
                />
              ) : null}
              <Button
                label="Listo"
                onPress={() => {
                  if (iosPicking) apply(iosPicking, draft);
                  setIosPicking(null);
                }}
              />
            </Pressable>
          </Pressable>
        </Modal>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: space.md },
  backdrop: { flex: 1, backgroundColor: colors.overlay, justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: colors.surface,
    borderTopLeftRadius: radius.xl,
    borderTopRightRadius: radius.xl,
    padding: space.xl,
    paddingBottom: space.xxxl,
    gap: space.lg,
  },
});
