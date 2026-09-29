import Ionicons from '@expo/vector-icons/Ionicons';
import { router } from 'expo-router';
import * as Linking from 'expo-linking';
import { useState } from 'react';
import { Alert, View } from 'react-native';

import { MenuRow, Stars } from '@/components/forms';
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
import { SUPPORT_EMAIL } from '@/legal/generated';
import { supabase } from '@/lib/supabase';
import type { Profile, ProfilePrivate } from '@/lib/types';
import { useAsync } from '@/lib/useAsync';
import { colors, space } from '@/theme';

type Reputation = { rating_avg: number | null; rating_count: number; completed_bookings: number };

async function loadProfile(userId: string) {
  const [pub, priv, rep, payout] = await Promise.all([
    supabase.from('profiles').select('*').eq('id', userId).single(),
    supabase.from('profile_private').select('*').eq('user_id', userId).single(),
    supabase.rpc('user_reputation', { p_user_id: userId }),
    supabase.from('payout_accounts').select('user_id').eq('user_id', userId).maybeSingle(),
  ]);
  if (pub.error) throw pub.error;
  if (priv.error) throw priv.error;
  if (rep.error) logError('profile.reputation', rep.error);
  if (payout.error) logError('profile.payout', payout.error);
  return {
    profile: pub.data as Profile,
    priv: priv.data as ProfilePrivate,
    reputation: (rep.data as Reputation | null) ?? null,
    hasPayout: !!payout.data,
  };
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
  const [deleting, setDeleting] = useState(false);
  const rep = data.reputation;

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
          // Este dispositivo deja de recibir avisos de esta cuenta
          const del = await supabase.from('push_tokens').delete().eq('user_id', userId as string);
          if (del.error) logError('push.unregister', del.error);
          const { error: err } = await supabase.auth.signOut();
          if (err) logError('auth.signOut', err);
        },
      },
    ]);

  const deleteAccount = () =>
    Alert.alert(
      'Eliminar cuenta',
      'Se borrarán tu perfil, tus datos privados, documentos y vehículos sin reservas. Esta acción no se puede deshacer.',
      [
        { text: 'Volver', style: 'cancel' },
        {
          text: 'Eliminar mi cuenta',
          style: 'destructive',
          onPress: async () => {
            setDeleting(true);
            setMessage(null);
            try {
              const { data: res, error: err } = await supabase.functions.invoke('delete-account', { body: {} });
              if (err) {
                const ctx = (err as { context?: Response }).context;
                const body = ctx ? ((await ctx.json().catch(() => null)) as { error?: string } | null) : null;
                throw new Error(body?.error ?? 'No pudimos eliminar tu cuenta. Escríbenos a soporte.');
              }
              if (!(res as { ok?: boolean })?.ok) throw new Error('No pudimos eliminar tu cuenta. Escríbenos a soporte.');
              await supabase.auth.signOut();
            } catch (e) {
              logError('account.delete', e);
              setMessage({ tone: 'error', text: e instanceof Error ? e.message : friendlyError(e) });
            } finally {
              setDeleting(false);
            }
          },
        },
      ],
    );

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
        {rep && rep.rating_count > 0 && rep.rating_avg !== null ? (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: space.sm }}>
            <Stars value={rep.rating_avg} size={16} />
            <Text variant="bodySmall">
              {rep.rating_avg} · {rep.rating_count} {rep.rating_count === 1 ? 'reseña' : 'reseñas'}
            </Text>
          </View>
        ) : (
          <Text variant="bodySmall" color="textSecondary">Aún no tienes reseñas.</Text>
        )}
        <Text variant="bodySmall" color="textSecondary">
          {rep?.completed_bookings ?? 0} arriendos completados
        </Text>
        <Verification ok={data.profile.identity_verified} label="Identidad verificada" />
        <Verification ok={data.profile.license_verified} label="Licencia de conducir verificada" />
        {!data.profile.identity_verified || !data.profile.license_verified ? (
          <Button label="Verificar mis documentos" variant="secondary" icon="shield-checkmark-outline" small onPress={() => router.push('/verify')} />
        ) : null}
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
      </View>

      <SectionHeader title="Propietario" />
      <MenuRow
        icon="card-outline"
        label="Datos bancarios"
        detail={data.hasPayout ? 'Listos' : 'Pendientes'}
        onPress={() => router.push('/payout')}
      />

      <SectionHeader title="Ayuda y legal" />
      <MenuRow icon="notifications-outline" label="Avisos" onPress={() => router.push('/notifications')} />
      <MenuRow
        icon="help-circle-outline"
        label="Soporte"
        detail={SUPPORT_EMAIL}
        onPress={() => Linking.openURL(`mailto:${SUPPORT_EMAIL}?subject=Ayuda%20RU%C3%89`).catch((e) => logError('support.mail', e))}
      />
      <MenuRow icon="document-text-outline" label="Términos y Condiciones" onPress={() => router.push({ pathname: '/legal/[doc]', params: { doc: 'terminos' } })} />
      <MenuRow icon="lock-closed-outline" label="Política de Privacidad" onPress={() => router.push({ pathname: '/legal/[doc]', params: { doc: 'privacidad' } })} />

      <View style={{ gap: space.md, marginTop: space.xl }}>
        <Button label="Cerrar sesión" variant="secondary" icon="log-out-outline" onPress={signOut} />
        <Button label="Eliminar cuenta" variant="danger" icon="trash-outline" onPress={deleteAccount} loading={deleting} />
      </View>
    </Screen>
  );
}
