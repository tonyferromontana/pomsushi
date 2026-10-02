import { useState } from 'react';
import { View } from 'react-native';

import { Stars } from '@/components/forms';
import { Avatar, Button, Card, Text } from '@/components/ui';
import { shortDate } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import { useAsync } from '@/lib/useAsync';
import { space } from '@/theme';

type ReviewRow = { id: string; rating: number; comment: string | null; created_at: string; author_id: string };
type Review = ReviewRow & { author_name: string; author_avatar: string | null };

const MAX = 20;

/**
 * Reseñas recibidas por una persona (las escribe la otra parte al finalizar una reserva,
 * vía submit_review). Con vehicleId, solo las de reservas de ese vehículo.
 */
async function loadReviews(targetUserId: string, vehicleId?: string): Promise<Review[]> {
  let q = supabase
    .from('reviews')
    .select('id, rating, comment, created_at, author_id')
    .eq('target_user_id', targetUserId)
    .order('created_at', { ascending: false })
    .limit(MAX);
  if (vehicleId) q = q.eq('vehicle_id', vehicleId);
  const { data, error } = await q;
  if (error) throw error;
  const rows = (data ?? []) as ReviewRow[];
  const ids = [...new Set(rows.map((r) => r.author_id))];
  const names: Record<string, { name: string; avatar: string | null }> = {};
  if (ids.length > 0) {
    const { data: ps, error: pe } = await supabase.from('profiles').select('id, display_name, avatar_url').in('id', ids);
    if (pe) throw pe;
    for (const p of (ps ?? []) as { id: string; display_name: string; avatar_url: string | null }[]) {
      names[p.id] = { name: p.display_name || 'Usuario RUÉ', avatar: p.avatar_url };
    }
  }
  return rows.map((r) => ({
    ...r,
    author_name: names[r.author_id]?.name ?? 'Usuario RUÉ',
    author_avatar: names[r.author_id]?.avatar ?? null,
  }));
}

export function ReviewsList({
  targetUserId,
  vehicleId,
  emptyText,
}: {
  targetUserId: string;
  vehicleId?: string;
  emptyText: string;
}) {
  const [showAll, setShowAll] = useState(false);
  const { data, error, loading } = useAsync(() => loadReviews(targetUserId, vehicleId), [targetUserId, vehicleId ?? '']);

  if (loading) {
    return (
      <Text variant="bodySmall" color="textSecondary">
        Cargando reseñas…
      </Text>
    );
  }
  if (error || !data) {
    return (
      <Text variant="bodySmall" color="textSecondary">
        No pudimos cargar las reseñas.
      </Text>
    );
  }
  if (data.length === 0) {
    return (
      <Text variant="bodySmall" color="textSecondary">
        {emptyText}
      </Text>
    );
  }

  const avg = data.reduce((s, r) => s + r.rating, 0) / data.length;
  const visible = showAll ? data : data.slice(0, 3);
  return (
    <View style={{ gap: space.md }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: space.sm }}>
        <Stars value={avg} size={18} />
        <Text variant="label">
          {avg.toFixed(1)} · {data.length === 1 ? '1 reseña' : `${data.length}${data.length === MAX ? '+' : ''} reseñas`}
        </Text>
      </View>
      {visible.map((r) => (
        <Card key={r.id} style={{ gap: space.sm }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: space.md }}>
            <Avatar name={r.author_name} uri={r.author_avatar} />
            <View style={{ flex: 1 }}>
              <Text variant="title">{r.author_name}</Text>
              <Text variant="caption" color="textSecondary">
                {shortDate(new Date(r.created_at))}
              </Text>
            </View>
            <Stars value={r.rating} size={14} />
          </View>
          {r.comment ? <Text variant="bodySmall">{r.comment}</Text> : null}
        </Card>
      ))}
      {data.length > 3 ? (
        <Button
          label={showAll ? 'Ver menos' : `Ver todas (${data.length})`}
          variant="ghost"
          small
          onPress={() => setShowAll((v) => !v)}
        />
      ) : null}
    </View>
  );
}
