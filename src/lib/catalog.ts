import type MaterialCommunityIcons from '@expo/vector-icons/MaterialCommunityIcons';
import type { ComponentProps } from 'react';

import type { ColorToken } from '@/theme';
import type { BookingPurpose, BookingStatus, VehicleAttributes, VehicleType } from './types';

type MciName = ComponentProps<typeof MaterialCommunityIcons>['name'];

/** Tipos de activo. El orden es el orden en que aparecen en la app. */
export const VEHICLE_TYPES: { value: VehicleType; label: string; icon: MciName }[] = [
  { value: 'car', label: 'Auto', icon: 'car' },
  { value: 'suv', label: 'SUV', icon: 'car-estate' },
  { value: 'pickup', label: 'Camioneta', icon: 'car-pickup' },
  { value: 'motorcycle', label: 'Moto', icon: 'motorbike' },
  { value: 'van', label: 'Van', icon: 'van-passenger' },
  { value: 'cargo_van', label: 'Furgón', icon: 'van-utility' },
  { value: 'truck', label: 'Camión', icon: 'truck' },
  { value: 'minibus', label: 'Minibús', icon: 'bus' },
  { value: 'trailer', label: 'Carro de arrastre', icon: 'truck-trailer' },
  { value: 'special', label: 'Especial', icon: 'tractor' },
];

export function vehicleTypeLabel(t: VehicleType): string {
  return VEHICLE_TYPES.find((v) => v.value === t)?.label ?? t;
}

export function vehicleTypeIcon(t: VehicleType): MciName {
  return VEHICLE_TYPES.find((v) => v.value === t)?.icon ?? 'car';
}

export const PURPOSES: { value: BookingPurpose; label: string }[] = [
  { value: 'viaje', label: 'Viaje' },
  { value: 'ciudad', label: 'Ciudad' },
  { value: 'trabajo', label: 'Trabajo' },
  { value: 'aplicaciones', label: 'Apps (Uber, DiDi, Cabify)' },
  { value: 'reparto', label: 'Reparto' },
  { value: 'carga', label: 'Carga' },
  { value: 'otro', label: 'Otro' },
];

export function purposeLabel(p: BookingPurpose): string {
  return PURPOSES.find((x) => x.value === p)?.label ?? p;
}

export const BOOKING_STATUS: Record<BookingStatus, { label: string; tone: ColorToken }> = {
  solicitada: { label: 'Solicitada', tone: 'warning' },
  aceptada: { label: 'Aceptada · falta el pago', tone: 'info' },
  confirmada: { label: 'Confirmada', tone: 'success' },
  en_curso: { label: 'En curso', tone: 'accent' },
  devuelta: { label: 'Devuelta', tone: 'info' },
  finalizada: { label: 'Finalizada', tone: 'textSecondary' },
  rechazada: { label: 'Rechazada', tone: 'error' },
  cancelada: { label: 'Cancelada', tone: 'textSecondary' },
  vencida: { label: 'Vencida', tone: 'textSecondary' },
  disputada: { label: 'En revisión', tone: 'error' },
};

/** Etapas del flujo feliz, para la línea de tiempo */
export const BOOKING_FLOW: BookingStatus[] = [
  'solicitada',
  'aceptada',
  'confirmada',
  'en_curso',
  'devuelta',
  'finalizada',
];

// -----------------------------------------------------------------------------
// Atributos por tipo (qué se pregunta al publicar y qué se muestra en la ficha)
// -----------------------------------------------------------------------------

type AttrKey = keyof VehicleAttributes;

export type AttributeField =
  | { key: AttrKey; label: string; kind: 'choice'; options: { value: string; label: string }[] }
  | { key: AttrKey; label: string; kind: 'number'; unit?: string; max: number };

const transmission: AttributeField = {
  key: 'transmission',
  label: 'Transmisión',
  kind: 'choice',
  options: [
    { value: 'manual', label: 'Manual' },
    { value: 'automatica', label: 'Automática' },
  ],
};
const fuel: AttributeField = {
  key: 'fuel',
  label: 'Combustible',
  kind: 'choice',
  options: [
    { value: 'bencina', label: 'Bencina' },
    { value: 'diesel', label: 'Diésel' },
    { value: 'hibrido', label: 'Híbrido' },
    { value: 'electrico', label: 'Eléctrico' },
    { value: 'gas', label: 'Gas' },
  ],
};
const traction: AttributeField = {
  key: 'traction',
  label: 'Tracción',
  kind: 'choice',
  options: [
    { value: '4x2', label: '4x2' },
    { value: '4x4', label: '4x4' },
    { value: 'awd', label: 'AWD' },
  ],
};
const seats: AttributeField = { key: 'seats', label: 'Asientos', kind: 'number', max: 60 };
const engine: AttributeField = { key: 'engine_cc', label: 'Cilindrada', kind: 'number', unit: 'cc', max: 20000 };
const cargoKg: AttributeField = { key: 'cargo_kg', label: 'Carga máxima', kind: 'number', unit: 'kg', max: 60000 };
const cargoM3: AttributeField = { key: 'cargo_m3', label: 'Volumen de carga', kind: 'number', unit: 'm³', max: 200 };
const license: AttributeField = {
  key: 'license_class',
  label: 'Licencia requerida',
  kind: 'choice',
  options: ['B', 'C', 'A2', 'A3', 'A4', 'A5', 'D'].map((v) => ({ value: v, label: `Clase ${v}` })),
};

export const ATTRIBUTE_FIELDS: Record<VehicleType, AttributeField[]> = {
  car: [transmission, fuel, seats],
  suv: [transmission, fuel, traction, seats],
  pickup: [transmission, fuel, traction, seats, cargoKg],
  motorcycle: [engine, fuel, license],
  van: [transmission, fuel, seats, license],
  cargo_van: [transmission, fuel, cargoKg, cargoM3],
  truck: [transmission, fuel, cargoKg, cargoM3, license],
  minibus: [transmission, fuel, seats, license],
  trailer: [cargoKg, cargoM3],
  special: [fuel, license],
};

export function attributeSummary(attrs: VehicleAttributes, t: VehicleType): string[] {
  return ATTRIBUTE_FIELDS[t]
    .map((f) => {
      const v = attrs[f.key];
      if (v === undefined || v === null || v === '') return null;
      if (f.kind === 'choice') return f.options.find((o) => o.value === v)?.label ?? String(v);
      if (f.key === 'seats') return `${v} asientos`;
      return `${String(v).replace(/\B(?=(\d{3})+(?!\d))/g, '.')}${f.unit ? ` ${f.unit}` : ''}`;
    })
    .filter((x): x is string => x !== null);
}

/** Zonas para registrar daños en las actas de entrega y devolución. */
export const DAMAGE_ZONES = [
  'Frente',
  'Parachoques delantero',
  'Parachoques trasero',
  'Costado izquierdo',
  'Costado derecho',
  'Techo',
  'Vidrios',
  'Neumáticos y llantas',
  'Interior',
  'Carga o carrocería',
  'Otro',
] as const;
