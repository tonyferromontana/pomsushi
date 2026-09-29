import Ionicons from '@expo/vector-icons/Ionicons';
import { useState } from 'react';
import { Alert, View } from 'react-native';

import {
  Avatar,
  Button,
  Card,
  ErrorState,
  Input,
  LoadingState,
  Notice,
  Screen,
  SectionHeader,
  Text,
} from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { memberSince } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import type { Profile, ProfilePrivate } from '@/lib/types';
import { useAsync } from '@/lib/useAsync';
import { colors, space } from '@/theme';

async function loadProfile(userId: string) {
  const [pub, priv] = await Promise.all([
    supabase.from('profiles').select('*').eq('id', userId).single(),
    supabase.from('profile_private').select('*').eq('user_id', userId).single(),
  ]);
  if (pub.error) throw pub.error;
  if (priv.error) throw priv.error;
  return { profile: pub.data as Profile, priv: priv.data as ProfilePrivate };
}

/** Normaliza el RUT a 12345678-5 (sin puntos, con guion, K mayúscula) */
function normalizeRut(input: string): string {
  const clean = input.replace(/[^0-9kK]/g, '').toUpperCase();
  if (clean.length < 2) return clean;
  return `${clean.slice(0, -1)}-${clean.slice(-1)}`;
}

function Verification({ ok, label }: { ok: boolean; label: string }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: space.sm }}>
      <Ionicons
        name={ok ? 'checkmark-circle' : 'ellipse-outline'}
        size={18}
        color={ok ? colors.accent : colors.textSecondary}
      />
      <Text variant="bodySmall" color={ok ? 'text' : 'textSecondary'}>
        {label}
        {ok ? '' : ' · pendiente'}
      </Text>
    </View>
  );
}

export default function ProfileScreen() {
  const { userId } = useAuth();
  const { data, error, loading, reload } = useAsync(() => loadProfile(userId as string), [userId], !!userId);

  if (loading && !data) return <LoadingState />;
  if (error || !data) {
    return (
      <Screen>
        <ErrorState message={friendlyError(error)} onRetry={reload} />
      </Screen>
    );
  }
  return <ProfileForm data={data} reload={reload} />;
}

function ProfileForm({
  data,
  reload,
}: {
  data: Awaited<ReturnType<typeof loadProfile>>;
  reload: () => Promise<void>;
}) {
  const { userId, session } = useAuth();
  const [name, setName] = useState(data.profile.display_name);
  const [city, setCity] = useState(data.profile.city ?? '');
  const [rut, setRut] = useState(data.priv.rut ?? '');
  const [phone, setPhone] = useState(data.priv.phone ?? '');
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'error'; text: string } | null>(null);

  const save = async () => {
    if (!userId) return;
    setSaving(true);
    setMessage(null);
    try {
      const a = await supabase
        .from('profiles')
        .update({ display_name: name.trim().slice(0, 60), city: city.trim() || null })
        .eq('id', userId);
      if (a.error) throw a.error;
      const b = await supabase
        .from('profile_private')
        .update({ rut: rut ? normalizeRut(rut) : null, phone: phone.trim() || null })
        .eq('user_id', userId);
      if (b.error) throw b.error;
      setMessage({ tone: 'success', text: 'Listo, guardamos tus datos.' });
      await reload();
    } catch (e) {
      logError('profile.save', e);
      setMessage({ tone: 'error', text: friendlyError(e) });
    } finally {
      setSaving(false);
    }
  };

  const signOut = () =>
    Alert.alert('Cerrar sesión', '¿Seguro que quieres salir?', [
      { text: 'Volver', style: 'cancel' },
      {
        text: 'Salir',
        style: 'destructive',
        onPress: async () => {
          const { error: err } = await supabase.auth.signOut();
          if (err) logError('auth.signOut', err);
        },
      },
    ]);

  return (
    <Screen scroll>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: space.lg, paddingTop: space.lg }}>
        <Avatar name={data.profile.display_name || '?'} uri={data.profile.avatar_url} />
        <View style={{ flex: 1 }}>
          <Text variant="h2">{data.profile.display_name || 'Tu perfil'}</Text>
          <Text variant="caption" color="textSecondary">
            {session?.user.email} · en RUÉ desde {memberSince(data.profile.created_at)}
          </Text>
        </View>
      </View>

      <SectionHeader title="Confianza" />
      <Card style={{ gap: space.sm }}>
        <Verification ok={data.profile.identity_verified} label="Identidad verificada" />
        <Verification ok={data.profile.license_verified} label="Licencia de conducir verificada" />
        <Text variant="caption" color="textSecondary">
          La verificación de documentos llega en una próxima versión.
        </Text>
      </Card>

      <SectionHeader title="Perfil público" />
      <View style={{ gap: space.md }}>
        <Input label="Nombre" value={name} onChangeText={setName} maxLength={60} />
        <Input label="Ciudad" value={city} onChangeText={setCity} maxLength={80} placeholder="Santiago" />
      </View>

      <SectionHeader title="Datos privados" />
      <View style={{ gap: space.md }}>
        <Notice>Solo tú puedes ver estos datos. Nunca se muestran a otros usuarios.</Notice>
        <Input
          label="RUT"
          value={rut}
          onChangeText={(v) => setRut(normalizeRut(v))}
          placeholder="12345678-5"
          autoCapitalize="characters"
          maxLength={10}
        />
        <Input
          label="Teléfono"
          value={phone}
          onChangeText={setPhone}
          placeholder="+56 9 1234 5678"
          keyboardType="phone-pad"
          maxLength={16}
        />
      </View>

      <View style={{ gap: space.md, marginTop: space.xl }}>
        {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
        <Button label="Guardar cambios" onPress={save} loading={saving} />
        <Button label="Cerrar sesión" variant="danger" icon="log-out-outline" onPress={signOut} />
      </View>
    </Screen>
  );
}
