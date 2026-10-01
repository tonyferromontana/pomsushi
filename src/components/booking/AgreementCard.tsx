import { useState } from 'react';
import { View } from 'react-native';

import { Button, Card, Divider, Row, Text } from '@/components/ui';
import { clp, shortDate } from '@/lib/format';
import type { BookingAgreement } from '@/lib/types';
import { space } from '@/theme';

type Economics = {
  rental_clp?: number;
  renter_service_fee_clp?: number;
  charged_clp?: number;
  owner_fee_clp?: number;
  owner_payout_clp?: number;
  guarantee_clp?: number;
  new_end_date?: string;
};

/**
 * Contrato digital generado por el servidor al confirmarse el pago (y un anexo por cada extensión).
 * El código de verificación es el hash del contenido: si alguien lo altera, no coincide.
 */
export function AgreementCard({ agreements, role }: { agreements: BookingAgreement[]; role: 'owner' | 'renter' }) {
  const [openId, setOpenId] = useState<string | null>(null);
  if (agreements.length === 0) return null;

  return (
    <Card style={{ gap: space.md }}>
      <Text variant="h3">Contrato digital</Text>
      {agreements.map((a) => {
        const eco = (a.content.economics ?? {}) as Economics;
        const isOpen = openId === a.id;
        return (
          <View key={a.id} style={{ gap: space.xs }}>
            <Text variant="title">{a.kind === 'contract' ? 'Contrato de arriendo' : `Anexo de extensión (v${a.version})`}</Text>
            <Text variant="caption" color="textSecondary">
              Términos {a.terms_version} · aceptado por ambas partes · {shortDate(new Date(a.created_at))}
            </Text>
            <Text variant="caption" color="textSecondary">
              Código de verificación: {a.content_sha256.slice(0, 16)}
            </Text>
            {isOpen ? (
              <View style={{ gap: space.xs, marginTop: space.xs }}>
                {eco.new_end_date ? <Row label="Nueva devolución" value={shortDate(eco.new_end_date)} /> : null}
                {eco.rental_clp != null ? <Row label="Arriendo" value={clp(eco.rental_clp)} /> : null}
                {role === 'renter' && eco.renter_service_fee_clp != null ? (
                  <Row label="Cargo de servicio" value={clp(eco.renter_service_fee_clp)} />
                ) : null}
                {role === 'renter' && eco.charged_clp != null ? <Row label="Total pagado" value={clp(eco.charged_clp)} strong /> : null}
                {role === 'owner' && eco.owner_fee_clp != null ? <Row label="Comisión RUÉ" value={`-${clp(eco.owner_fee_clp)}`} /> : null}
                {role === 'owner' && eco.owner_payout_clp != null ? <Row label="Recibes" value={clp(eco.owner_payout_clp)} strong /> : null}
                {eco.guarantee_clp != null ? <Row label="Garantía referencial (aún no se cobra)" value={clp(eco.guarantee_clp)} /> : null}
                <Divider spacing={space.sm} />
                <Text variant="caption" color="textSecondary">
                  Incluye vehículo, patente, fechas y horas, kilometraje, combustible, lugar de entrega, montos y las
                  autorizaciones que aceptaste. RUÉ guarda los datos legales de ambas partes.
                </Text>
              </View>
            ) : null}
            <Button label={isOpen ? 'Ocultar' : 'Ver detalle'} variant="ghost" small onPress={() => setOpenId(isOpen ? null : a.id)} />
          </View>
        );
      })}
    </Card>
  );
}
