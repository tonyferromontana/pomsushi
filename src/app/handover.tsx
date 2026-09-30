import Ionicons from '@expo/vector-icons/Ionicons';
import { Image } from 'expo-image';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { router, Stack, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { Button, Chip, Input, Notice, Screen, Text } from '@/components/ui';
import { friendlyError, logError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { colors, radius, space } from '@/theme';

const FUEL = [0, 25, 50, 75, 100];
const MAX_PHOTOS = 12;

/**
 * Acta de entrega o devolución (cláusula 11 de los Términos).
 * Cualquiera de las partes puede registrar su acta u observación. Las fotos son privadas de la reserva.
 */
export default function HandoverScreen() {
  const { booking, kind } = useLocalSearchParams<{ booking: string; kind: 'entrega' | 'devolucion' }>();
  const [km, setKm] = useState('');
  const [fuel, setFuel] = useState<number | null>(null);
  const [notes, setNotes] = useState('');
  const [photos, setPhotos] = useState<string[]>([]);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const title = kind === 'devolucion' ? 'Acta de devolución' : 'Acta de entrega';

  const addPhoto = async () => {
    setError(null);
    const perm = await ImagePicker.requestCameraPermissionsAsync();
    const res = perm.granted
      ? await ImagePicker.launchCameraAsync({ mediaTypes: ['images'], quality: 1 })
      : await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], quality: 1, allowsMultipleSelection: true });
    if (res.canceled) return;
    setPhotos((p) => [...p, ...res.assets.map((a) => a.uri)].slice(0, MAX_PHOTOS));
  };

  const submit = async () => {
    const odometer = parseInt(km.replace(/\D/g, ''), 10);
    if (!Number.isFinite(odometer)) return setError('Anota el kilometraje del tablero.');
    if (fuel === null) return setError('Indica el nivel de combustible o carga.');
    if (photos.length < 4) return setError('Toma al menos 4 fotos: frente, atrás y ambos costados.');
    setSending(true);
    setError(null);
    try {
      const paths: string[] = [];
      const stamp = Date.now();
      for (const [i, uri] of photos.entries()) {
        const ctx = ImageManipulator.manipulate(uri);
        ctx.resize({ width: 1600 });
        const img = await ctx.renderAsync();
        const out = await img.saveAsync({ compress: 0.75, format: SaveFormat.JPEG });
        const path = `${booking}/${kind}-${stamp}-${i}.jpg`;
        const up = await supabase.storage.from('handovers').upload(path, await (await fetch(out.uri)).arrayBuffer(), {
          contentType: 'image/jpeg',
        });
        if (up.error) throw up.error;
        paths.push(path);
      }
      const { error: err } = await supabase.rpc('submit_handover', {
        p_booking_id: booking,
        p_kind: kind,
        p_odometer_km: odometer,
        p_fuel_level: fuel,
        p_notes: notes.trim() || null,
        p_photo_paths: paths,
      });
      if (err) throw err;
      router.back();
    } catch (e) {
      logError('handover.submit', e);
      setError(friendlyError(e, 'No pudimos guardar el acta. Revisa tu conexión e inténtalo de nuevo.'));
    } finally {
      setSending(false);
    }
  };

  return (
    <Screen
      scroll
      edges={['bottom']}
      footer={
        <View style={{ gap: space.sm }}>
          {error ? <Notice tone="error">{error}</Notice> : null}
          <Button label="Guardar acta" onPress={submit} loading={sending} />
        </View>
      }
    >
      <Stack.Screen options={{ title }} />
      <View style={{ gap: space.lg, paddingTop: space.lg }}>
        <Text color="textSecondary">
          Revisen el vehículo juntos. Esta acta queda guardada para ambos y sirve como respaldo si hay un reclamo.
        </Text>
        <Input
          label="Kilometraje del tablero"
          keyboardType="number-pad"
          placeholder="Ej: 45.230"
          value={km}
          onChangeText={(v) => setKm(v.replace(/[^\d.]/g, ''))}
          icon="speedometer-outline"
        />
        <View style={{ gap: space.sm }}>
          <Text variant="label" color="textSecondary">
            Combustible o carga
          </Text>
          <View style={styles.wrap}>
            {FUEL.map((f) => (
              <Chip key={f} label={f === 0 ? 'Reserva' : f === 100 ? 'Lleno' : `${f} %`} selected={fuel === f} onPress={() => setFuel(f)} />
            ))}
          </View>
        </View>
        <Input
          label="Observaciones"
          placeholder="Daños previos, rayones, accesorios, llaves, documentos…"
          value={notes}
          onChangeText={setNotes}
          multiline
          maxLength={2000}
        />
        <View style={{ gap: space.sm }}>
          <Text variant="label" color="textSecondary">
            Fotos ({photos.length}/{MAX_PHOTOS}) · mínimo 4
          </Text>
          <View style={styles.wrap}>
            {photos.map((uri, i) => (
              <View key={uri + i} style={styles.photo}>
                <Image source={{ uri }} style={StyleSheet.absoluteFill} contentFit="cover" />
                <Pressable
                  accessibilityLabel="Quitar foto"
                  onPress={() => setPhotos((p) => p.filter((_, j) => j !== i))}
                  style={styles.remove}
                >
                  <Ionicons name="close" size={14} color={colors.text} />
                </Pressable>
              </View>
            ))}
            {photos.length < MAX_PHOTOS ? (
              <Pressable onPress={addPhoto} style={[styles.photo, styles.add]} accessibilityRole="button" accessibilityLabel="Agregar foto">
                <Ionicons name="camera-outline" size={24} color={colors.textSecondary} />
              </Pressable>
            ) : null}
          </View>
        </View>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  wrap: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
  photo: { width: '31%', aspectRatio: 1, borderRadius: radius.md, overflow: 'hidden', backgroundColor: colors.surface },
  add: { alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderStyle: 'dashed', borderColor: colors.border },
  remove: {
    position: 'absolute',
    top: space.xs,
    right: space.xs,
    width: 24,
    height: 24,
    borderRadius: radius.pill,
    backgroundColor: colors.scrim,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
