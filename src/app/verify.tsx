import Ionicons from '@expo/vector-icons/Ionicons';
import { Image } from 'expo-image';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { Badge, Button, ErrorState, LoadingState, Notice, Screen, SectionHeader, Segmented, Text } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { useAsync } from '@/lib/useAsync';
import { colors, radius, space } from '@/theme';

type Kind = 'license' | 'identity';
type Request = { id: string; kind: Kind; status: 'pendiente' | 'aprobada' | 'rechazada'; review_note: string | null; created_at: string };

const LABEL: Record<Kind, string> = { license: 'Licencia de conducir', identity: 'Cédula de identidad' };
const STATUS = {
  pendiente: { label: 'En revisión', tone: 'warning' },
  aprobada: { label: 'Aprobada', tone: 'accent' },
  rechazada: { label: 'Rechazada', tone: 'error' },
} as const;

async function load(userId: string) {
  const [req, prof] = await Promise.all([
    supabase.from('verification_requests').select('id, kind, status, review_note, created_at').eq('user_id', userId).order('created_at', { ascending: false }),
    supabase.from('profiles').select('identity_verified, license_verified').eq('id', userId).single(),
  ]);
  if (req.error) throw req.error;
  if (prof.error) throw prof.error;
  return { requests: (req.data ?? []) as Request[], profile: prof.data as { identity_verified: boolean; license_verified: boolean } };
}

async function compressDoc(uri: string): Promise<ArrayBuffer> {
  const ctx = ImageManipulator.manipulate(uri);
  ctx.resize({ width: 1800 });
  const img = await ctx.renderAsync();
  const out = await img.saveAsync({ compress: 0.8, format: SaveFormat.JPEG });
  return (await fetch(out.uri)).arrayBuffer();
}

export default function VerifyScreen() {
  const { userId } = useAuth();
  const { data, error, loading, reload } = useAsync(() => load(userId as string), [userId], !!userId);
  const [kind, setKind] = useState<Kind>('license');
  const [front, setFront] = useState<string | null>(null);
  const [back, setBack] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'error'; text: string } | null>(null);

  if (loading && !data) return <LoadingState />;
  if (error || !data) return <ErrorState message={friendlyError(error)} onRetry={reload} />;

  const verified = kind === 'license' ? data.profile.license_verified : data.profile.identity_verified;
  const pending = data.requests.find((r) => r.kind === kind && r.status === 'pendiente');
  const last = data.requests.find((r) => r.kind === kind);

  const pick = async (side: 'front' | 'back') => {
    const perm = await ImagePicker.requestCameraPermissionsAsync();
    const res = perm.granted
      ? await ImagePicker.launchCameraAsync({ mediaTypes: ['images'], quality: 1 })
      : await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], quality: 1 });
    if (res.canceled) return;
    if (side === 'front') setFront(res.assets[0].uri);
    else setBack(res.assets[0].uri);
  };

  const submit = async () => {
    if (!userId || !front || !back) return;
    setSending(true);
    setMessage(null);
    try {
      const stamp = Date.now();
      const paths: string[] = [];
      for (const [side, uri] of [['frente', front], ['reverso', back]] as const) {
        const path = `${userId}/${kind}-${side}-${stamp}.jpg`;
        const up = await supabase.storage.from('documents').upload(path, await compressDoc(uri), { contentType: 'image/jpeg' });
        if (up.error) throw up.error;
        paths.push(path);
      }
      const { error: err } = await supabase.rpc('submit_verification', { p_kind: kind, p_front_path: paths[0], p_back_path: paths[1] });
      if (err) throw err;
      setFront(null);
      setBack(null);
      setMessage({ tone: 'success', text: 'Recibimos tus fotos. Te avisaremos cuando estén revisadas.' });
      await reload();
    } catch (e) {
      logError('verify.submit', e);
      setMessage({ tone: 'error', text: friendlyError(e) });
    } finally {
      setSending(false);
    }
  };

  return (
    <Screen scroll edges={['bottom']}>
      <View style={{ gap: space.lg, paddingTop: space.lg }}>
        <Text variant="h2">Verifica tu cuenta</Text>
        <Text color="textSecondary">
          Genera confianza con los propietarios. Tus documentos son privados: solo el equipo de RUÉ los revisa y nunca
          se muestran a otros usuarios.
        </Text>
        <Segmented
          options={[
            { value: 'license', label: 'Licencia' },
            { value: 'identity', label: 'Cédula' },
          ]}
          value={kind}
          onChange={(k) => {
            setKind(k);
            setFront(null);
            setBack(null);
            setMessage(null);
          }}
        />
      </View>

      <SectionHeader title={LABEL[kind]} />
      {verified ? (
        <Notice tone="success">Tu {LABEL[kind].toLowerCase()} ya está verificada.</Notice>
      ) : pending ? (
        <View style={{ gap: space.sm }}>
          <Badge label={STATUS.pendiente.label} tone="warning" />
          <Text color="textSecondary">La estamos revisando. Normalmente toma menos de 24 horas hábiles.</Text>
        </View>
      ) : (
        <View style={{ gap: space.lg }}>
          {last?.status === 'rechazada' ? (
            <Notice tone="error">{last.review_note ?? 'No pudimos validar tu documento. Envíalo de nuevo con buena luz y sin reflejos.'}</Notice>
          ) : null}
          <View style={styles.row}>
            {(['front', 'back'] as const).map((side) => {
              const uri = side === 'front' ? front : back;
              return (
                <Pressable key={side} onPress={() => pick(side)} style={styles.tile} accessibilityRole="button">
                  {uri ? (
                    <Image source={{ uri }} style={StyleSheet.absoluteFill} contentFit="cover" />
                  ) : (
                    <>
                      <Ionicons name="camera-outline" size={26} color={colors.textSecondary} />
                      <Text variant="caption" color="textSecondary">
                        {side === 'front' ? 'Frente' : 'Reverso'}
                      </Text>
                    </>
                  )}
                </Pressable>
              );
            })}
          </View>
          {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
          <Button label="Enviar a revisión" onPress={submit} loading={sending} disabled={!front || !back} />
        </View>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: space.md },
  tile: {
    flex: 1,
    aspectRatio: 1.58,
    borderRadius: radius.md,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: colors.border,
    backgroundColor: colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
    gap: space.xs,
  },
});
