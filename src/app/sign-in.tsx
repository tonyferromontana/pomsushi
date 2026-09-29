import { Link } from 'expo-router';
import { useRef, useState } from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, View, type TextInput } from 'react-native';

import { Checkbox } from '@/components/forms';
import { Button, Input, Notice, Screen, Segmented, Text, Wordmark } from '@/components/ui';
import { TERMS_VERSION } from '@/legal/generated';
import { track } from '@/lib/analytics';
import { friendlyError, logError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { space } from '@/theme';

type Mode = 'signin' | 'signup';

export default function SignInScreen() {
  const [mode, setMode] = useState<Mode>('signin');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [acceptTerms, setAcceptTerms] = useState(false);
  const [isAdult, setIsAdult] = useState(false);
  const passwordRef = useRef<TextInput>(null);

  const submit = async () => {
    setError(null);
    setInfo(null);
    const cleanEmail = email.trim().toLowerCase();
    if (!/^\S+@\S+\.\S+$/.test(cleanEmail)) return setError('Escribe un correo válido.');
    if (password.length < 6) return setError('La contraseña debe tener al menos 6 caracteres.');
    if (mode === 'signup' && name.trim().length < 2) return setError('Cuéntanos cómo te llamas.');
    if (mode === 'signup' && !isAdult) return setError('RUÉ es solo para mayores de 18 años.');
    if (mode === 'signup' && !acceptTerms) return setError('Para crear tu cuenta debes aceptar los Términos y la Política de Privacidad.');

    setBusy(true);
    try {
      if (mode === 'signin') {
        const { error: err } = await supabase.auth.signInWithPassword({ email: cleanEmail, password });
        if (err) throw err;
      } else {
        track('signup_started');
        const { data, error: err } = await supabase.auth.signUp({
          email: cleanEmail,
          password,
          options: { data: { display_name: name.trim(), terms_version: TERMS_VERSION } },
        });
        if (err) throw err;
        track('signup_completed');
        if (!data.session) {
          setInfo('Te enviamos un correo para confirmar tu cuenta. Ábrelo y después vuelve aquí para entrar.');
          setMode('signin');
        }
      }
    } catch (e) {
      logError('auth', e);
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Screen edges={['top', 'bottom']}>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}>
        <ScrollView
          contentContainerStyle={{ flexGrow: 1, justifyContent: 'center', gap: space.xl, paddingVertical: space.xl }}
          keyboardShouldPersistTaps="handled"
        >
          <View style={{ gap: space.md }}>
            <Wordmark size={48} />
            <Text variant="h2">Haz producir lo que tienes parado.</Text>
            <Text color="textSecondary">
              Arrienda autos, motos, camionetas, furgones y más, directo de sus dueños.
            </Text>
          </View>

          <Segmented
            options={[
              { value: 'signin', label: 'Entrar' },
              { value: 'signup', label: 'Crear cuenta' },
            ]}
            value={mode}
            onChange={(m) => {
              setMode(m);
              setError(null);
            }}
          />

          <View style={{ gap: space.md }}>
            {mode === 'signup' ? (
              <Input
                label="Nombre"
                placeholder="Como quieres que te vean"
                value={name}
                onChangeText={setName}
                autoComplete="name"
                textContentType="name"
                returnKeyType="next"
              />
            ) : null}
            <Input
              label="Correo"
              placeholder="tu@correo.cl"
              value={email}
              onChangeText={setEmail}
              autoCapitalize="none"
              autoComplete="email"
              keyboardType="email-address"
              textContentType="emailAddress"
              returnKeyType="next"
              onSubmitEditing={() => passwordRef.current?.focus()}
            />
            <Input
              ref={passwordRef}
              label="Contraseña"
              placeholder="Mínimo 6 caracteres"
              value={password}
              onChangeText={setPassword}
              secureTextEntry
              autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
              textContentType={mode === 'signin' ? 'password' : 'newPassword'}
              returnKeyType="go"
              onSubmitEditing={submit}
            />
          </View>

          {mode === 'signup' ? (
            <View style={{ gap: space.md }}>
              <Checkbox checked={isAdult} onChange={setIsAdult}>
                Tengo 18 años o más.
              </Checkbox>
              <Checkbox checked={acceptTerms} onChange={setAcceptTerms}>
                <Text variant="bodySmall">
                  Acepto los{' '}
                  <Link href={{ pathname: '/legal/[doc]', params: { doc: 'terminos' } }}>
                    <Text variant="bodySmall" color="accent">Términos y Condiciones</Text>
                  </Link>{' '}
                  y la{' '}
                  <Link href={{ pathname: '/legal/[doc]', params: { doc: 'privacidad' } }}>
                    <Text variant="bodySmall" color="accent">Política de Privacidad</Text>
                  </Link>
                  .
                </Text>
              </Checkbox>
            </View>
          ) : null}

          {error ? <Notice tone="error">{error}</Notice> : null}
          {info ? <Notice tone="success">{info}</Notice> : null}

          <Button label={mode === 'signin' ? 'Entrar' : 'Crear cuenta'} onPress={submit} loading={busy} />
        </ScrollView>
      </KeyboardAvoidingView>
    </Screen>
  );
}
