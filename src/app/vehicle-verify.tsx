import Ionicons from '@expo/vector-icons/Ionicons';
import * as DocumentPicker from 'expo-document-picker';
import { useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { DateField } from '@/components/DateRangeField';
import { Badge, Button, ErrorState, LoadingState, Notice, Screen, SectionHeader, Text } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { friendlyError, logError } from '@/lib/errors';
import { addDays, fromISODate, shortDate, startOfToday } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import { useAsync } from '@/lib/useAsync';
import { colors, radius, space } from '@/theme';

type Req = { id: string; status: 'pendiente' | 'aprobada' | 'rechazada'; review_note: string | null; created_at: string };
type Picked = { uri: string; name: string; mimeType: string };

async function load(vehicleId: string) {
  const [v, reqs] = await Promise.all([
    supabase.from('vehicles').select('id, title, plate, verified, verified_until').eq('id', vehicleId).single(),
    supabase.from('vehicle_verifications').select('id, status, review_note, created_at').eq('vehicle_id', vehicleId).order('created_at', { ascending: false }),
  ]);
  if (v.error) throw v.error;
  if (reqs.error) throw reqs.error;
  return {
    vehicle: v.data as { id: string; title: string; plate: string | null; verified: boolean; verified_until: string | null },
    requests: (reqs.data ?? []) as Req[],
  };
}

function FilePick({ label, file, onPick }: { label: string; file: Picked | null; onPick: (f: Picked) => void }) {
  const pick = async () => {
    const res = await DocumentPicker.getDocumentAsync({ type: ['application/pdf', 'image/*'], copyToCacheDirectory: true });
    if (res.canceled) return;
    const a = res.assets[0];
    onPick({ uri: a.uri, name: a.name, mimeType: a.mimeType ?? 'application/pdf' });
  };
  return (
    <Pressable onPress={pick} accessibilityRole="button" style={styles.file}>
      <Ionicons name={file ? 'document-attach' : 'cloud-upload-outline'} size={22} color={file ? colors.accent : colors.textSecondary} />
      <View style={{ flex: 1 }}>
        <Text variant="label">{label}</Text>
        <Text variant="caption" color="textSecondary" numberOfLines={1}>
          {file ? file.name : 'PDF o foto'}
        </Text>
      </View>
    </Pressable>
  );
}

/** Cláusula 4: acreditar que eres el propietario inscrito del vehículo. */
export default function VehicleVerifyScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const { data, error, loading, reload } = useAsync(() => load(id), [id]);
  const [cav, setCav] = useState<Picked | null>(null);
  const [padron, setPadron] = useState<Picked | null>(null);
  const [issuedOn, setIssuedOn] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'error'; text: string } | null>(null);

  if (loading && !data) return <LoadingState />;
  if (error || !data) return <ErrorState message={friendlyError(error)} onRetry={reload} />;

  const { vehicle, requests } = data;
  const pending = requests.find((r) => r.status === 'pendiente');
  const lastRejected = requests[0]?.status === 'rechazada' ? requests[0] : null;
  const valid = vehicle.verified && vehicle.verified_until && fromISODate(vehicle.verified_until) >= new Date();

  const submit = async () => {
    if (!userId || !cav || !padron || !issuedOn) return;
    setSending(true);
    setMessage(null);
    try {
      const stamp = Date.now();
      const paths: string[] = [];
      for (const [name, f] of [['cav', cav], ['padron', padron]] as const) {
        const ext = f.mimeType === 'application/pdf' ? 'pdf' : 'jpg';
        const path = `${userId}/vehiculo-${vehicle.id}-${name}-${stamp}.${ext}`;
        const body = await (await fetch(f.uri)).arrayBuffer();
        const up = await supabase.storage.from('documents').upload(path, body, {
          contentType: f.mimeType === 'application/pdf' ? 'application/pdf' : 'image/jpeg',
        });
        if (up.error) throw up.error;
        paths.push(path);
      }
      const { error: err } = await supabase.rpc('submit_vehicle_verification', {
        p_vehicle_id: vehicle.id,
        p_cav_path: paths[0],
        p_padron_path: paths[1],
        p_cav_issued_on: issuedOn,
      });
      if (err) throw err;
      setCav(null);
      setPadron(null);
      setIssuedOn(null);
      setMessage({ tone: 'success', text: 'Recibimos tus documentos. Te avisaremos cuando estén revisados.' });
      await reload();
    } catch (e) {
      logError('vehicleVerify.submit', e);
      setMessage({ tone: 'error', text: friendlyError(e) });
    } finally {
      setSending(false);
    }
  };

  return (
    <Screen scroll edges={['bottom']}>
      <View style={{ gap: space.md, paddingTop: space.lg }}>
        <Text variant="h2">Acredita que el vehículo es tuyo</Text>
        <Text color="textSecondary">
          {vehicle.title}
          {vehicle.plate ? ` · ${vehicle.plate}` : ''}
        </Text>
        {valid && vehicle.verified_until ? (
          <Badge label={`Verificado hasta el ${shortDate(vehicle.verified_until)}`} tone="accent" />
        ) : null}
      </View>

      {pending ? (
        <View style={{ marginTop: space.xl }}>
          <Notice tone="warning">Estamos revisando tus documentos. Normalmente toma menos de 24 horas hábiles.</Notice>
        </View>
      ) : (
        <>
          <SectionHeader title="Qué necesitas" />
          <View style={{ gap: space.sm }}>
            <Text variant="bodySmall" color="textSecondary">
              • Certificado de Anotaciones Vigentes del Registro Civil, emitido hace máximo 30 días. Lo descargas en
              registrocivil.cl con la patente.
            </Text>
            <Text variant="bodySmall" color="textSecondary">
              • Padrón o certificado de inscripción del vehículo.
            </Text>
            <Text variant="bodySmall" color="textSecondary">
              • Tu cédula verificada en Perfil → Verificar mis documentos. El nombre y RUT del certificado deben coincidir
              con los tuyos.
            </Text>
            <Text variant="bodySmall" color="textSecondary">
              • La verificación dura 6 meses; después te pediremos un certificado nuevo.
            </Text>
          </View>

          {lastRejected ? (
            <View style={{ marginTop: space.lg }}>
              <Notice tone="error">{lastRejected.review_note ?? 'No pudimos validar los documentos. Revísalos y vuelve a enviarlos.'}</Notice>
            </View>
          ) : null}

          <View style={{ gap: space.md, marginTop: space.xl }}>
            <FilePick label="Certificado de Anotaciones Vigentes" file={cav} onPick={setCav} />
            <FilePick label="Padrón" file={padron} onPick={setPadron} />
            <DateField
              label="Fecha de emisión del certificado"
              value={issuedOn}
              onChange={setIssuedOn}
              minimumDate={addDays(startOfToday(), -30)}
              maximumDate={startOfToday()}
            />
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
            <Button label="Enviar a revisión" onPress={submit} loading={sending} disabled={!cav || !padron || !issuedOn} />
          </View>
        </>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  file: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
    padding: space.lg,
    borderRadius: radius.md,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
});
