import MaterialCommunityIcons from '@expo/vector-icons/MaterialCommunityIcons';
import Ionicons from '@expo/vector-icons/Ionicons';
import { Image } from 'expo-image';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { Button, Chip, ErrorState, Input, LoadingState, Notice, Screen, Text } from '@/components/ui';
import { track } from '@/lib/analytics';
import { useAuth } from '@/lib/auth';
import { ATTRIBUTE_FIELDS, PURPOSES, VEHICLE_TYPES, vehicleTypeLabel } from '@/lib/catalog';
import { friendlyError, logError } from '@/lib/errors';
import { clp } from '@/lib/format';
import { photoUrl, supabase, VEHICLE_PHOTOS_BUCKET } from '@/lib/supabase';
import type { BookingPurpose, ListingStatus, Vehicle, VehicleAttributes, VehicleType } from '@/lib/types';
import { colors, photoAspect, radius, space } from '@/theme';

// -----------------------------------------------------------------------------

type PhotoItem = { key: string; path?: string; localUri?: string };

type Form = {
  vehicle_type: VehicleType | null;
  title: string;
  brand: string;
  model: string;
  year: string;
  city: string;
  comuna: string;
  description: string;
  attributes: VehicleAttributes;
  use_cases: BookingPurpose[];
  daily_price: string;
  weekly_price: string;
  deposit: string;
  min_days: string;
};

const EMPTY: Form = {
  vehicle_type: null,
  title: '',
  brand: '',
  model: '',
  year: '',
  city: '',
  comuna: '',
  description: '',
  attributes: {},
  use_cases: [],
  daily_price: '',
  weekly_price: '',
  deposit: '',
  min_days: '1',
};

const STEPS = ['Tipo', 'Datos', 'Fotos', 'Precio', 'Revisar'] as const;
const MAX_PHOTOS = 10;

/** Identificador aleatorio para nombres de archivo e ids nuevos (no es un secreto). */
function uuid(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

const digits = (s: string) => s.replace(/[^0-9]/g, '');
const toInt = (s: string) => (digits(s) ? parseInt(digits(s), 10) : null);
const thousands = (s: string) => {
  const d = digits(s);
  return d ? parseInt(d, 10).toLocaleString('es-CL').replace(/,/g, '.') : '';
};

function validate(step: number, f: Form, photos: PhotoItem[]): string | null {
  if (step === 0 && !f.vehicle_type) return 'Elige qué quieres publicar.';
  if (step === 1) {
    if (f.title.trim().length < 3) return 'Ponle un título de al menos 3 letras.';
    if (!f.brand.trim() || !f.model.trim()) return 'Completa la marca y el modelo.';
    const y = toInt(f.year);
    if (!y || y < 1950 || y > new Date().getFullYear() + 1) return 'Revisa el año.';
    if (f.city.trim().length < 2) return '¿En qué ciudad está?';
  }
  if (step === 2 && photos.length === 0) return 'Agrega al menos una foto.';
  if (step === 3) {
    const d = toInt(f.daily_price);
    if (!d || d < 1000) return 'El precio por día debe ser de al menos $1.000.';
    const w = toInt(f.weekly_price);
    if (w !== null && w < 1000) return 'Revisa el precio semanal.';
    const m = toInt(f.min_days);
    if (!m || m < 1 || m > 90) return 'Los días mínimos deben estar entre 1 y 90.';
  }
  return null;
}

async function compress(uri: string): Promise<string> {
  const ctx = ImageManipulator.manipulate(uri);
  ctx.resize({ width: 1600 });
  const img = await ctx.renderAsync();
  const out = await img.saveAsync({ compress: 0.75, format: SaveFormat.JPEG });
  return out.uri;
}

// -----------------------------------------------------------------------------

export default function PublishScreen() {
  const { id: editId } = useLocalSearchParams<{ id?: string }>();
  const { userId } = useAuth();
  const [vehicleId] = useState(() => editId ?? uuid());
  const [step, setStep] = useState(editId ? 1 : 0);
  const [form, setForm] = useState<Form>(EMPTY);
  const [photos, setPhotos] = useState<PhotoItem[]>([]);
  const [originalPaths, setOriginalPaths] = useState<string[]>([]);
  const [loading, setLoading] = useState(!!editId);
  const [loadError, setLoadError] = useState<unknown>(null);
  const [stepError, setStepError] = useState<string | null>(null);
  const [saving, setSaving] = useState<ListingStatus | null>(null);

  useEffect(() => {
    if (!editId) {
      track('listing_started');
      return;
    }
    (async () => {
      try {
        const [{ data: v, error }, { data: ph, error: phErr }] = await Promise.all([
          supabase.from('vehicles').select('*').eq('id', editId).single(),
          supabase.from('vehicle_photos').select('*').eq('vehicle_id', editId).order('position'),
        ]);
        if (error) throw error;
        if (phErr) throw phErr;
        const veh = v as Vehicle;
        setForm({
          vehicle_type: veh.vehicle_type,
          title: veh.title,
          brand: veh.brand,
          model: veh.model,
          year: String(veh.year),
          city: veh.city,
          comuna: veh.comuna ?? '',
          description: veh.description ?? '',
          attributes: veh.attributes ?? {},
          use_cases: veh.use_cases ?? [],
          daily_price: thousands(String(veh.daily_price_clp)),
          weekly_price: veh.weekly_price_clp ? thousands(String(veh.weekly_price_clp)) : '',
          deposit: veh.deposit_clp ? thousands(String(veh.deposit_clp)) : '',
          min_days: String(veh.min_days),
        });
        const items = (ph ?? []).map((p: { id: string; storage_path: string }) => ({ key: p.id, path: p.storage_path }));
        setPhotos(items);
        setOriginalPaths(items.map((p) => p.path as string));
      } catch (e) {
        logError('publish.load', e);
        setLoadError(e);
      } finally {
        setLoading(false);
      }
    })();
  }, [editId]);

  const set = <K extends keyof Form>(key: K, value: Form[K]) => setForm((f) => ({ ...f, [key]: value }));
  const fields = useMemo(() => (form.vehicle_type ? ATTRIBUTE_FIELDS[form.vehicle_type] : []), [form.vehicle_type]);

  const next = () => {
    const err = validate(step, form, photos);
    setStepError(err);
    if (!err) setStep((s) => Math.min(s + 1, STEPS.length - 1));
  };
  const back = () => {
    setStepError(null);
    if (step === 0 || (editId && step === 1)) router.back();
    else setStep((s) => s - 1);
  };

  const pickPhotos = async () => {
    setStepError(null);
    const perm = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (!perm.granted) {
      setStepError('Necesitamos permiso para ver tus fotos. Actívalo en Ajustes.');
      return;
    }
    const res = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ['images'],
      allowsMultipleSelection: true,
      selectionLimit: MAX_PHOTOS - photos.length,
      quality: 1,
    });
    if (res.canceled) return;
    const added = res.assets.slice(0, MAX_PHOTOS - photos.length).map((a) => ({ key: uuid(), localUri: a.uri }));
    setPhotos((p) => [...p, ...added]);
  };

  const save = async (status: ListingStatus) => {
    if (!userId || !form.vehicle_type) return;
    for (let s = 0; s < STEPS.length - 1; s++) {
      const err = validate(s, form, photos);
      if (err) {
        setStep(s);
        setStepError(err);
        return;
      }
    }
    setSaving(status);
    setStepError(null);
    try {
      const payload = {
        vehicle_type: form.vehicle_type,
        status,
        title: form.title.trim(),
        brand: form.brand.trim(),
        model: form.model.trim(),
        year: toInt(form.year) as number,
        city: form.city.trim(),
        comuna: form.comuna.trim() || null,
        description: form.description.trim() || null,
        attributes: Object.fromEntries(
          Object.entries(form.attributes).filter(([k, v]) => v !== undefined && v !== '' && fields.some((f) => f.key === k)),
        ),
        use_cases: form.use_cases,
        daily_price_clp: toInt(form.daily_price) as number,
        weekly_price_clp: toInt(form.weekly_price),
        deposit_clp: toInt(form.deposit) ?? 0,
        min_days: toInt(form.min_days) ?? 1,
      };

      const { error } = editId
        ? await supabase.from('vehicles').update(payload).eq('id', vehicleId)
        : await supabase.from('vehicles').insert({ ...payload, id: vehicleId, owner_id: userId });
      if (error) throw error;

      // Fotos: subir las nuevas (comprimidas), borrar las quitadas, guardar el orden.
      const finalPaths: string[] = [];
      for (const p of photos) {
        if (p.path) {
          finalPaths.push(p.path);
          continue;
        }
        const uri = await compress(p.localUri as string);
        const body = await (await fetch(uri)).arrayBuffer();
        const path = `${userId}/${vehicleId}/${uuid()}.jpg`;
        const up = await supabase.storage.from(VEHICLE_PHOTOS_BUCKET).upload(path, body, { contentType: 'image/jpeg' });
        if (up.error) throw up.error;
        finalPaths.push(path);
      }

      const removed = originalPaths.filter((p) => !finalPaths.includes(p));
      const del = await supabase.from('vehicle_photos').delete().eq('vehicle_id', vehicleId);
      if (del.error) throw del.error;
      if (finalPaths.length > 0) {
        const ins = await supabase
          .from('vehicle_photos')
          .insert(finalPaths.map((storage_path, position) => ({ vehicle_id: vehicleId, storage_path, position })));
        if (ins.error) throw ins.error;
      }
      if (removed.length > 0) {
        const rm = await supabase.storage.from(VEHICLE_PHOTOS_BUCKET).remove(removed);
        if (rm.error) logError('publish.removePhotos', rm.error);
      }

      if (!editId && status === 'publicado') track('listing_completed', { vehicle_type: form.vehicle_type });
      router.back();
    } catch (e) {
      logError('publish.save', e);
      setStepError(friendlyError(e, 'No pudimos guardar tu publicación. Revisa tu conexión e inténtalo de nuevo.'));
    } finally {
      setSaving(null);
    }
  };

  if (loading) return <LoadingState />;
  if (loadError) return <ErrorState message={friendlyError(loadError)} onRetry={() => router.back()} />;

  const isLast = step === STEPS.length - 1;
  const footer = (
    <View style={{ gap: space.sm }}>
      {stepError ? <Notice tone="error">{stepError}</Notice> : null}
      <View style={{ flexDirection: 'row', gap: space.sm }}>
        <Button label={step === 0 || (editId && step === 1) ? 'Cerrar' : 'Atrás'} variant="ghost" onPress={back} />
        {isLast ? (
          <Button
            label="Publicar"
            onPress={() => save('publicado')}
            loading={saving === 'publicado'}
            disabled={saving !== null}
            style={{ flex: 1 }}
          />
        ) : (
          <Button label="Siguiente" onPress={next} style={{ flex: 1 }} />
        )}
      </View>
      {isLast ? (
        <Button
          label="Guardar como borrador"
          variant="secondary"
          onPress={() => save('borrador')}
          loading={saving === 'borrador'}
          disabled={saving !== null}
        />
      ) : null}
    </View>
  );

  return (
    <Screen scroll edges={['bottom']} footer={footer}>
      <View style={styles.progress}>
        {STEPS.map((s, i) => (
          <View key={s} style={[styles.progressStep, { backgroundColor: i <= step ? colors.accent : colors.border }]} />
        ))}
      </View>
      <Text variant="overline" color="textSecondary" style={{ marginTop: space.lg }}>
        PASO {step + 1} DE {STEPS.length} · {STEPS[step].toUpperCase()}
      </Text>

      {step === 0 ? (
        <View style={styles.section}>
          <Text variant="h1">¿Qué quieres publicar?</Text>
          <View style={styles.grid}>
            {VEHICLE_TYPES.map((t) => {
              const selected = form.vehicle_type === t.value;
              return (
                <Pressable
                  key={t.value}
                  accessibilityRole="button"
                  accessibilityState={{ selected }}
                  onPress={() => setForm((f) => ({ ...f, vehicle_type: t.value, attributes: {} }))}
                  style={[styles.typeTile, selected && { borderColor: colors.accent, backgroundColor: colors.surfaceRaised }]}
                >
                  <MaterialCommunityIcons name={t.icon} size={28} color={selected ? colors.accent : colors.text} />
                  <Text variant="label">{t.label}</Text>
                </Pressable>
              );
            })}
          </View>
        </View>
      ) : null}

      {step === 1 && form.vehicle_type ? (
        <View style={styles.section}>
          <Text variant="h1">Cuéntanos de tu {vehicleTypeLabel(form.vehicle_type).toLowerCase()}</Text>
          <Input
            label="Título"
            placeholder="Ej: Hilux 4x4 lista para la nieve"
            value={form.title}
            onChangeText={(v) => set('title', v)}
            maxLength={80}
          />
          <View style={styles.row2}>
            <View style={{ flex: 1 }}>
              <Input label="Marca" placeholder="Toyota" value={form.brand} onChangeText={(v) => set('brand', v)} maxLength={40} />
            </View>
            <View style={{ flex: 1 }}>
              <Input label="Modelo" placeholder="Hilux" value={form.model} onChangeText={(v) => set('model', v)} maxLength={40} />
            </View>
          </View>
          <View style={styles.row2}>
            <View style={{ flex: 1 }}>
              <Input
                label="Año"
                placeholder="2021"
                keyboardType="number-pad"
                value={form.year}
                onChangeText={(v) => set('year', digits(v).slice(0, 4))}
              />
            </View>
            <View style={{ flex: 1 }}>
              <Input label="Ciudad" placeholder="Santiago" value={form.city} onChangeText={(v) => set('city', v)} maxLength={80} />
            </View>
          </View>
          <Input
            label="Comuna (opcional)"
            placeholder="Providencia"
            value={form.comuna}
            onChangeText={(v) => set('comuna', v)}
            hint="Mostramos la comuna, nunca tu dirección exacta."
            maxLength={80}
          />

          {fields.map((f) =>
            f.kind === 'choice' ? (
              <View key={f.key} style={{ gap: space.sm }}>
                <Text variant="label" color="textSecondary">
                  {f.label}
                </Text>
                <View style={styles.wrap}>
                  {f.options.map((o) => {
                    const selected = form.attributes[f.key] === o.value;
                    return (
                      <Chip
                        key={o.value}
                        label={o.label}
                        selected={selected}
                        onPress={() =>
                          set('attributes', { ...form.attributes, [f.key]: selected ? undefined : o.value })
                        }
                      />
                    );
                  })}
                </View>
              </View>
            ) : (
              <Input
                key={f.key}
                label={`${f.label}${f.unit ? ` (${f.unit})` : ''}`}
                keyboardType="number-pad"
                value={form.attributes[f.key] !== undefined ? String(form.attributes[f.key]) : ''}
                onChangeText={(v) => {
                  const n = toInt(v);
                  set('attributes', { ...form.attributes, [f.key]: n === null ? undefined : Math.min(n, f.max) });
                }}
              />
            ),
          )}

          <Input
            label="Descripción (opcional)"
            placeholder="Estado, qué incluye, cómo es la entrega…"
            value={form.description}
            onChangeText={(v) => set('description', v)}
            multiline
            maxLength={2000}
          />
        </View>
      ) : null}

      {step === 2 ? (
        <View style={styles.section}>
          <Text variant="h1">Fotos</Text>
          <Text color="textSecondary">
            Buena luz, de día y desde varios ángulos. La primera es la portada. Hasta {MAX_PHOTOS} fotos.
          </Text>
          <View style={styles.photoGrid}>
            {photos.map((p, i) => {
              const uri = p.localUri ?? photoUrl(p.path);
              return (
                <View key={p.key} style={styles.photoTile}>
                  {uri ? <Image source={{ uri }} style={StyleSheet.absoluteFill} contentFit="cover" /> : null}
                  {i === 0 ? (
                    <View style={styles.coverTag}>
                      <Text variant="caption" color="onAccent">
                        Portada
                      </Text>
                    </View>
                  ) : (
                    <Pressable
                      accessibilityLabel="Usar como portada"
                      onPress={() => setPhotos((ps) => [ps[i], ...ps.filter((_, j) => j !== i)])}
                      style={[styles.photoAction, { left: space.xs }]}
                    >
                      <Ionicons name="star-outline" size={16} color={colors.text} />
                    </Pressable>
                  )}
                  <Pressable
                    accessibilityLabel="Quitar foto"
                    onPress={() => setPhotos((ps) => ps.filter((x) => x.key !== p.key))}
                    style={[styles.photoAction, { right: space.xs }]}
                  >
                    <Ionicons name="close" size={16} color={colors.text} />
                  </Pressable>
                </View>
              );
            })}
            {photos.length < MAX_PHOTOS ? (
              <Pressable accessibilityRole="button" onPress={pickPhotos} style={[styles.photoTile, styles.addTile]}>
                <Ionicons name="camera-outline" size={26} color={colors.textSecondary} />
                <Text variant="caption" color="textSecondary">
                  Agregar
                </Text>
              </Pressable>
            ) : null}
          </View>
        </View>
      ) : null}

      {step === 3 ? (
        <View style={styles.section}>
          <Text variant="h1">Precio y reglas</Text>
          <Text color="textSecondary">Tú defines cuánto pides. RUÉ calcula el total de cada reserva.</Text>
          <Input
            label="Precio por día (CLP)"
            placeholder="35.000"
            keyboardType="number-pad"
            value={form.daily_price}
            onChangeText={(v) => set('daily_price', thousands(v))}
            icon="cash-outline"
          />
          <Input
            label="Precio por semana (opcional)"
            placeholder="200.000"
            keyboardType="number-pad"
            value={form.weekly_price}
            onChangeText={(v) => set('weekly_price', thousands(v))}
            hint="Se aplica a arriendos de 7 días o más. Ideal para conductores de apps."
          />
          <Input
            label="Garantía (opcional)"
            placeholder="150.000"
            keyboardType="number-pad"
            value={form.deposit}
            onChangeText={(v) => set('deposit', thousands(v))}
            hint="Monto que respalda el cuidado del vehículo y se devuelve al terminar."
          />
          <Input
            label="Mínimo de días"
            keyboardType="number-pad"
            value={form.min_days}
            onChangeText={(v) => set('min_days', digits(v).slice(0, 2))}
          />
          <View style={{ gap: space.sm }}>
            <Text variant="label" color="textSecondary">
              ¿Para qué sirve? (opcional)
            </Text>
            <View style={styles.wrap}>
              {PURPOSES.map((p) => {
                const selected = form.use_cases.includes(p.value);
                return (
                  <Chip
                    key={p.value}
                    label={p.label}
                    selected={selected}
                    onPress={() =>
                      set('use_cases', selected ? form.use_cases.filter((u) => u !== p.value) : [...form.use_cases, p.value])
                    }
                  />
                );
              })}
            </View>
          </View>
        </View>
      ) : null}

      {step === 4 && form.vehicle_type ? (
        <View style={styles.section}>
          <Text variant="h1">Todo listo</Text>
          <View style={styles.summary}>
            {photos[0] ? (
              <Image
                source={{ uri: photos[0].localUri ?? photoUrl(photos[0].path) ?? undefined }}
                style={styles.summaryPhoto}
                contentFit="cover"
              />
            ) : null}
            <View style={{ padding: space.lg, gap: space.xs }}>
              <Text variant="overline" color="textSecondary">
                {`${vehicleTypeLabel(form.vehicle_type)} · ${form.comuna || form.city}`.toUpperCase()}
              </Text>
              <Text variant="h3">{form.title}</Text>
              <Text variant="bodySmall" color="textSecondary">
                {form.brand} {form.model} {form.year} · {photos.length} fotos
              </Text>
              <Text variant="price">
                {clp(toInt(form.daily_price) ?? 0)}
                <Text variant="bodySmall" color="textSecondary">
                  {' / día'}
                </Text>
              </Text>
            </View>
          </View>
          <Notice>
            Pronto te pediremos los documentos del vehículo para marcarlo como verificado. Los documentos nunca se
            muestran a otros usuarios.
          </Notice>
        </View>
      ) : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  progress: { flexDirection: 'row', gap: space.xs, marginTop: space.lg },
  progressStep: { flex: 1, height: 4, borderRadius: 2 },
  section: { gap: space.lg, marginTop: space.md },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: space.md },
  typeTile: {
    width: '47%',
    flexGrow: 1,
    height: 96,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    padding: space.lg,
    justifyContent: 'space-between',
  },
  row2: { flexDirection: 'row', gap: space.md },
  wrap: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
  photoGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
  photoTile: {
    width: '31%',
    aspectRatio: 1,
    borderRadius: radius.md,
    overflow: 'hidden',
    backgroundColor: colors.surface,
  },
  addTile: {
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: colors.border,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.xs,
  },
  coverTag: {
    position: 'absolute',
    left: space.xs,
    bottom: space.xs,
    backgroundColor: colors.accent,
    borderRadius: radius.sm,
    paddingHorizontal: space.xs,
  },
  photoAction: {
    position: 'absolute',
    top: space.xs,
    width: 28,
    height: 28,
    borderRadius: radius.pill,
    backgroundColor: colors.scrim,
    alignItems: 'center',
    justifyContent: 'center',
  },
  summary: { borderRadius: radius.lg, overflow: 'hidden', backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  summaryPhoto: { width: '100%', aspectRatio: photoAspect },
});
