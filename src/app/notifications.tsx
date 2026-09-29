import Ionicons from '@expo/vector-icons/Ionicons';
import { router, useFocusEffect } from 'expo-router';
import { useCallback } from 'react';
import { FlatList, Pressable, RefreshControl, StyleSheet, View } from 'react-native';

import { EmptyState, ErrorState, LoadingState, Screen, Text } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { shortDate, timeOfDay } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import { useAsync } from '@/lib/useAsync';
import { colors, radius, space } from '@/theme';

type Notice = {
  id: string;
  kind: string;
  title: string;
  body: string;
  booking_id: string | null;
  read_at: string | null;
  created_at: string;
};

async function load(userId: string): Promise<Notice[]> {
  const { data, error } = await supabase
    .from('notifications')
    .select('id, kind, title, body, booking_id, read_at, created_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) throw error;
  return (data ?? []) as Notice[];
}

export default function NotificationsScreen() {
  const { userId } = useAuth();
  const { data, error, loading, reload } = useAsync(() => load(userId as string), [userId], !!userId);

  // Al salir de la pantalla, todo queda como leído.
  useFocusEffect(
    useCallback(() => {
      return () => {
        if (!userId) return;
        supabase
          .from('notifications')
          .update({ read_at: new Date().toISOString() })
          .eq('user_id', userId)
          .is('read_at', null)
          .then(({ error: err }) => err && logError('notifications.read', err));
      };
    }, [userId]),
  );

  if (loading && !data) return <LoadingState />;
  if (error) return <ErrorState message={friendlyError(error)} onRetry={reload} />;

  return (
    <Screen edges={['bottom']} padded={false}>
      <FlatList
        data={data}
        keyExtractor={(n) => n.id}
        contentContainerStyle={{ padding: space.lg, gap: space.sm, flexGrow: 1 }}
        refreshControl={<RefreshControl refreshing={loading} onRefresh={reload} tintColor={colors.accent} />}
        ListEmptyComponent={
          <EmptyState icon="notifications-outline" title="Sin avisos por ahora" body="Aquí verás novedades de tus reservas y mensajes." />
        }
        renderItem={({ item: n }) => (
          <Pressable
            accessibilityRole="button"
            disabled={!n.booking_id}
            onPress={() => n.booking_id && router.push({ pathname: '/booking/[id]', params: { id: n.booking_id } })}
            style={({ pressed }) => [styles.row, pressed && { backgroundColor: colors.surfaceRaised }]}
          >
            <View style={[styles.dot, { backgroundColor: n.read_at ? 'transparent' : colors.accent }]} />
            <View style={{ flex: 1, gap: space.xxs }}>
              <Text variant="title">{n.title}</Text>
              <Text variant="bodySmall" color="textSecondary">
                {n.body}
              </Text>
              <Text variant="caption" color="textSecondary">
                {shortDate(new Date(n.created_at))} · {timeOfDay(n.created_at)}
              </Text>
            </View>
            {n.booking_id ? <Ionicons name="chevron-forward" size={18} color={colors.textSecondary} /> : null}
          </Pressable>
        )}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
    padding: space.lg,
    borderRadius: radius.lg,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
  },
  dot: { width: 8, height: 8, borderRadius: 4 },
});
