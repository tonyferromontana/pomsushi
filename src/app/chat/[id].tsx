import Ionicons from '@expo/vector-icons/Ionicons';
import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { FlatList, KeyboardAvoidingView, Platform, Pressable, StyleSheet, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { EmptyState, ErrorState, LoadingState, Text } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { timeOfDay } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import type { Message } from '@/lib/types';
import { colors, radius, size, space, type } from '@/theme';

export default function ChatScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<unknown>(null);
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let alive = true;
    supabase
      .from('messages')
      .select('*')
      .eq('booking_id', id)
      .order('created_at', { ascending: false })
      .limit(200)
      .then(({ data, error: err }) => {
        if (!alive) return;
        if (err) {
          logError('messages.load', err);
          setError(err);
        } else {
          setError(null);
          setMessages((data ?? []) as Message[]);
        }
        setLoading(false);
      });

    // Mensajes nuevos en tiempo real (RLS: solo participantes los reciben)
    const channel = supabase
      .channel(`chat-${id}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'messages', filter: `booking_id=eq.${id}` },
        (payload) => {
          const m = payload.new as Message;
          setMessages((prev) => (prev.some((x) => x.id === m.id) ? prev : [m, ...prev]));
        },
      )
      .subscribe();

    return () => {
      alive = false;
      void supabase.removeChannel(channel);
    };
  }, [id, attempt]);

  const send = async () => {
    const body = draft.trim();
    if (!body || !userId || sending) return;
    setSending(true);
    setSendError(null);
    try {
      const { data, error: err } = await supabase
        .from('messages')
        .insert({ booking_id: id, sender_id: userId, body })
        .select()
        .single();
      if (err) throw err;
      const m = data as Message;
      setMessages((prev) => (prev.some((x) => x.id === m.id) ? prev : [m, ...prev]));
      setDraft('');
    } catch (e) {
      logError('messages.send', e);
      setSendError(friendlyError(e, 'No se pudo enviar. Inténtalo de nuevo.'));
    } finally {
      setSending(false);
    }
  };

  if (loading) return <LoadingState />;
  if (error) {
    return (
      <ErrorState
        message={friendlyError(error)}
        onRetry={() => {
          setLoading(true);
          setAttempt((n) => n + 1);
        }}
      />
    );
  }

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: colors.background }} edges={['bottom']}>
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        keyboardVerticalOffset={Platform.OS === 'ios' ? 100 : 0}
      >
        {messages.length === 0 ? (
          <EmptyState
            icon="chatbubble-outline"
            title="Conversen aquí"
            body="Coordinen la entrega y la devolución aquí. Antes del pago ocultamos teléfonos y correos. No pagues por fuera de RUÉ: fuera de la app no hay pago con Webpay, contrato, actas ni soporte."
          />
        ) : (
          <FlatList
            data={messages}
            inverted
            keyExtractor={(m) => m.id}
            contentContainerStyle={{ padding: space.lg, gap: space.sm }}
            renderItem={({ item: m }) => {
              const mine = m.sender_id === userId;
              return (
                <View style={[styles.bubble, mine ? styles.mine : styles.theirs]}>
                  <Text variant="body" color={mine ? 'onAccent' : 'text'}>
                    {m.body}
                  </Text>
                  {m.moderation?.masked ? (
                    <Text variant="caption" color={mine ? 'onAccent' : 'textSecondary'}>
                      Ocultamos un dato de contacto: se puede compartir cuando la reserva esté pagada.
                    </Text>
                  ) : null}
                  <Text variant="caption" color={mine ? 'onAccent' : 'textSecondary'} align="right">
                    {timeOfDay(m.created_at)}
                  </Text>
                </View>
              );
            }}
          />
        )}

        {sendError ? (
          <Text variant="caption" color="error" style={{ paddingHorizontal: space.lg }}>
            {sendError}
          </Text>
        ) : null}
        <View style={styles.composer}>
          <TextInput
            style={styles.input}
            value={draft}
            onChangeText={setDraft}
            placeholder="Escribe un mensaje"
            placeholderTextColor={colors.textSecondary}
            selectionColor={colors.accent}
            multiline
            maxLength={2000}
          />
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Enviar"
            onPress={send}
            disabled={!draft.trim() || sending}
            style={[styles.send, (!draft.trim() || sending) && { backgroundColor: colors.disabled }]}
          >
            <Ionicons name="arrow-up" size={20} color={draft.trim() ? colors.onAccent : colors.onDisabled} />
          </Pressable>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  bubble: { maxWidth: '80%', borderRadius: radius.lg, paddingHorizontal: space.md, paddingVertical: space.sm, gap: space.xxs },
  mine: { alignSelf: 'flex-end', backgroundColor: colors.accent, borderBottomRightRadius: radius.sm },
  theirs: { alignSelf: 'flex-start', backgroundColor: colors.surfaceRaised, borderBottomLeftRadius: radius.sm },
  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: space.sm,
    padding: space.md,
    borderTopWidth: size.hairline,
    borderTopColor: colors.border,
  },
  input: {
    flex: 1,
    minHeight: 44,
    maxHeight: 120,
    borderRadius: radius.lg,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    paddingHorizontal: space.lg,
    paddingTop: space.md,
    paddingBottom: space.md,
    color: colors.text,
    ...type.body,
  },
  send: {
    width: 44,
    height: 44,
    borderRadius: radius.pill,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
