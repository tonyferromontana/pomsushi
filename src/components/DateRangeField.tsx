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

/** Campo de una sola fecha (por ejemplo, fecha de emisión de un certificado). */
export function DateField({
  label,
  value,
  onChange,
  minimumDate,
  maximumDate,
}: {
  label: string;
  value: string | null;
  onChange: (iso: string) => void;
  minimumDate?: Date;
  maximumDate?: Date;
}) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<Date>(value ? fromISODate(value) : maximumDate ?? startOfToday());

  const show = () => {
    const current = value ? fromISODate(value) : maximumDate ?? startOfToday();
    if (Platform.OS === 'android') {
      DateTimePickerAndroid.open({
        value: current,
        mode: 'date',
        minimumDate,
        maximumDate,
        onChange: (event: DateTimePickerEvent, d?: Date) => {
          if (event.type === 'set' && d) onChange(toISODate(d));
        },
      });
      return;
    }
    setDraft(current);
    setOpen(true);
  };

  return (
    <>
      <FieldButton label={label} icon="calendar-outline" placeholder="Elegir fecha" value={value ? shortDate(value) : null} onPress={show} />
      {Platform.OS === 'ios' ? (
        <Modal visible={open} transparent animationType="fade" onRequestClose={() => setOpen(false)}>
          <Pressable style={styles.backdrop} onPress={() => setOpen(false)}>
            <Pressable style={styles.sheet} onPress={() => undefined}>
              <Text variant="h3">{label}</Text>
              <DateTimePicker
                value={draft}
                mode="date"
                display="inline"
                themeVariant="dark"
                accentColor={colors.accent}
                locale="es-CL"
                minimumDate={minimumDate}
                maximumDate={maximumDate}
                onChange={(_e, d) => d && setDraft(d)}
              />
              <Button
                label="Listo"
                onPress={() => {
                  onChange(toISODate(draft));
                  setOpen(false);
                }}
              />
            </Pressable>
          </Pressable>
        </Modal>
      ) : null}
    </>
  );
}

/** Campo de hora 'HH:MM' (por ejemplo, hora de entrega propuesta por el propietario). */
export function TimeField({ label, value, onChange }: { label: string; value: string; onChange: (hhmm: string) => void }) {
  const [open, setOpen] = useState(false);
  const toDate = (hhmm: string) => {
    const [h, m] = hhmm.split(':').map(Number);
    const d = new Date();
    d.setHours(h || 0, m || 0, 0, 0);
    return d;
  };
  const toHHMM = (d: Date) => `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  const [draft, setDraft] = useState<Date>(toDate(value));

  const show = () => {
    if (Platform.OS === 'android') {
      DateTimePickerAndroid.open({
        value: toDate(value),
        mode: 'time',
        is24Hour: true,
        minuteInterval: 15,
        onChange: (event: DateTimePickerEvent, d?: Date) => {
          if (event.type === 'set' && d) onChange(toHHMM(d));
        },
      });
      return;
    }
    setDraft(toDate(value));
    setOpen(true);
  };

  return (
    <>
      <FieldButton label={label} icon="time-outline" placeholder="Elegir hora" value={value} onPress={show} style={{ flex: 1 }} />
      {Platform.OS === 'ios' ? (
        <Modal visible={open} transparent animationType="fade" onRequestClose={() => setOpen(false)}>
          <Pressable style={styles.backdrop} onPress={() => setOpen(false)}>
            <Pressable style={styles.sheet} onPress={() => undefined}>
              <Text variant="h3">{label}</Text>
              <DateTimePicker
                value={draft}
                mode="time"
                display="spinner"
                themeVariant="dark"
                locale="es-CL"
                minuteInterval={15}
                onChange={(_e, d) => d && setDraft(d)}
              />
              <Button
                label="Listo"
                onPress={() => {
                  onChange(toHHMM(draft));
                  setOpen(false);
                }}
              />
            </Pressable>
          </Pressable>
        </Modal>
      ) : null}
    </>
  );
}
