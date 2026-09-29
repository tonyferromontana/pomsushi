import { useState } from 'react';
import { View } from 'react-native';

import { Button, Chip, ErrorState, Input, LoadingState, Notice, Screen, Text } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { useAsync } from '@/lib/useAsync';
import { space } from '@/theme';

type Account = {
  holder_name: string;
  holder_rut: string;
  bank: string;
  account_type: 'corriente' | 'vista' | 'ahorro' | 'rut';
  account_number: string;
  email: string | null;
};

const TYPES = [
  { value: 'corriente', label: 'Corriente' },
  { value: 'vista', label: 'Vista' },
  { value: 'rut', label: 'CuentaRUT' },
  { value: 'ahorro', label: 'Ahorro' },
] as const;

function normalizeRut(input: string): string {
  const clean = input.replace(/[^0-9kK]/g, '').toUpperCase();
  return clean.length < 2 ? clean : `${clean.slice(0, -1)}-${clean.slice(-1)}`;
}

async function load(userId: string): Promise<Account | null> {
  const { data, error } = await supabase.from('payout_accounts').select('*').eq('user_id', userId).maybeSingle();
  if (error) throw error;
  return data as Account | null;
}

export default function PayoutScreen() {
  const { userId } = useAuth();
  const { data, error, loading, reload } = useAsync(() => load(userId as string), [userId], !!userId);
  if (loading && data === undefined) return <LoadingState />;
  if (error) return <ErrorState message={friendlyError(error)} onRetry={reload} />;
  return <PayoutForm initial={data ?? null} />;
}

function PayoutForm({ initial }: { initial: Account | null }) {
  const { userId } = useAuth();
  const [form, setForm] = useState<Account>(
    initial ?? { holder_name: '', holder_rut: '', bank: '', account_type: 'vista', account_number: '', email: null },
  );
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'error'; text: string } | null>(null);

  const save = async () => {
    if (!userId) return;
    if (form.holder_name.trim().length < 3 || !/^\d{7,8}-[\dK]$/.test(form.holder_rut) || form.bank.trim().length < 2 || !/^[\d-]{4,20}$/.test(form.account_number)) {
      setMessage({ tone: 'error', text: 'Revisa que todos los datos estén completos y el RUT tenga el formato 12345678-5.' });
      return;
    }
    setSaving(true);
    setMessage(null);
    try {
      const { error } = await supabase.from('payout_accounts').upsert({
        user_id: userId,
        holder_name: form.holder_name.trim(),
        holder_rut: form.holder_rut,
        bank: form.bank.trim(),
        account_type: form.account_type,
        account_number: form.account_number,
        email: form.email?.trim() || null,
      });
      if (error) throw error;
      setMessage({ tone: 'success', text: 'Listo. Aquí te transferiremos lo que ganes con tus vehículos.' });
    } catch (e) {
      logError('payout.save', e);
      setMessage({ tone: 'error', text: friendlyError(e) });
    } finally {
      setSaving(false);
    }
  };

  return (
    <Screen scroll edges={['bottom']}>
      <View style={{ gap: space.lg, paddingTop: space.lg }}>
        <Text variant="h2">¿Dónde te pagamos?</Text>
        <Notice>Estos datos son privados. Solo se usan para transferirte lo que ganes con tus arriendos.</Notice>
        <Input label="Titular de la cuenta" value={form.holder_name} onChangeText={(v) => setForm({ ...form, holder_name: v })} maxLength={80} />
        <Input
          label="RUT del titular"
          placeholder="12345678-5"
          value={form.holder_rut}
          onChangeText={(v) => setForm({ ...form, holder_rut: normalizeRut(v) })}
          autoCapitalize="characters"
          maxLength={10}
        />
        <Input label="Banco" placeholder="BancoEstado" value={form.bank} onChangeText={(v) => setForm({ ...form, bank: v })} maxLength={60} />
        <View style={{ gap: space.sm }}>
          <Text variant="label" color="textSecondary">Tipo de cuenta</Text>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: space.sm }}>
            {TYPES.map((t) => (
              <Chip key={t.value} label={t.label} selected={form.account_type === t.value} onPress={() => setForm({ ...form, account_type: t.value })} />
            ))}
          </View>
        </View>
        <Input
          label="Número de cuenta"
          keyboardType="number-pad"
          value={form.account_number}
          onChangeText={(v) => setForm({ ...form, account_number: v.replace(/[^0-9-]/g, '') })}
          maxLength={20}
        />
        <Input
          label="Correo para el aviso de transferencia (opcional)"
          keyboardType="email-address"
          autoCapitalize="none"
          value={form.email ?? ''}
          onChangeText={(v) => setForm({ ...form, email: v })}
        />
        {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
        <Button label="Guardar" onPress={save} loading={saving} />
      </View>
    </Screen>
  );
}
