/**
 * Tipos del dominio. Reflejan supabase/migrations (0001, 0002).
 * Si cambias el esquema, actualiza este archivo en la misma tarea.
 */

export type VehicleType =
  | 'car'
  | 'motorcycle'
  | 'suv'
  | 'pickup'
  | 'van'
  | 'cargo_van'
  | 'truck'
  | 'minibus'
  | 'trailer'
  | 'special';

export type ListingStatus = 'borrador' | 'publicado' | 'pausado';

export type BookingStatus =
  | 'solicitada'
  | 'aceptada'
  | 'confirmada'
  | 'en_curso'
  | 'devuelta'
  | 'finalizada'
  | 'rechazada'
  | 'cancelada'
  | 'vencida'
  | 'disputada';

export type BookingPurpose =
  | 'viaje'
  | 'ciudad'
  | 'trabajo'
  | 'aplicaciones'
  | 'reparto'
  | 'carga'
  | 'otro';

export type VehicleAttributes = {
  transmission?: 'manual' | 'automatica';
  fuel?: 'bencina' | 'diesel' | 'hibrido' | 'electrico' | 'gas';
  seats?: number;
  doors?: number;
  traction?: '4x2' | '4x4' | 'awd';
  engine_cc?: number;
  cargo_kg?: number;
  cargo_m3?: number;
  body?: string;
  license_class?: 'A1' | 'A2' | 'A3' | 'A4' | 'A5' | 'B' | 'C' | 'D';
};

export type Profile = {
  id: string;
  display_name: string;
  avatar_url: string | null;
  bio: string | null;
  city: string | null;
  identity_verified: boolean;
  license_verified: boolean;
  created_at: string;
};

export type ProfilePrivate = {
  user_id: string;
  rut: string | null;
  phone: string | null;
  birth_date: string | null;
  address: string | null;
};

export type Vehicle = {
  id: string;
  owner_id: string;
  vehicle_type: VehicleType;
  status: ListingStatus;
  title: string;
  brand: string;
  model: string;
  year: number;
  description: string | null;
  city: string;
  comuna: string | null;
  attributes: VehicleAttributes;
  use_cases: BookingPurpose[];
  daily_price_clp: number;
  weekly_price_clp: number | null;
  deposit_clp: number;
  min_days: number;
  verified: boolean;
  verified_until: string | null;
  plate: string | null;
  km_per_day: number | null;
  pickup_location: string | null;
  fuel_policy: 'mismo_nivel' | 'lleno';
  insurance_info: string | null;
  created_at: string;
};

export type Handover = {
  id: string;
  booking_id: string;
  kind: 'entrega' | 'devolucion';
  author_id: string;
  odometer_km: number | null;
  fuel_level: number | null;
  notes: string | null;
  photo_paths: string[];
  created_at: string;
};

export type VehiclePhoto = {
  id: string;
  vehicle_id: string;
  storage_path: string;
  position: number;
};

/** Fila que devuelve la función search_vehicles() */
export type VehicleSearchResult = Pick<
  Vehicle,
  | 'id'
  | 'owner_id'
  | 'vehicle_type'
  | 'title'
  | 'brand'
  | 'model'
  | 'year'
  | 'city'
  | 'comuna'
  | 'attributes'
  | 'use_cases'
  | 'daily_price_clp'
  | 'weekly_price_clp'
  | 'min_days'
  | 'verified'
> & { owner_name: string; cover_path: string | null };

export type Booking = {
  id: string;
  vehicle_id: string;
  renter_id: string;
  owner_id: string;
  status: BookingStatus;
  purpose: BookingPurpose | null;
  start_date: string;
  end_date: string;
  days: number;
  rental_clp: number;
  renter_fee_clp: number;
  owner_commission_clp: number;
  total_clp: number;
  owner_payout_clp: number;
  deposit_clp: number;
  renter_message: string | null;
  expires_at: string | null;
  created_at: string;
  updated_at: string;
};

export type BookingEvent = {
  id: number;
  booking_id: string;
  from_status: BookingStatus | null;
  to_status: BookingStatus;
  actor_id: string | null;
  note: string | null;
  created_at: string;
};

export type Message = {
  id: string;
  booking_id: string;
  sender_id: string;
  body: string;
  read_at: string | null;
  created_at: string;
};

/** Respuesta de quote_booking(): la calcula el servidor, la app solo la muestra */
export type Quote = {
  days: number;
  rental_clp: number;
  renter_fee_clp: number;
  total_clp: number;
  deposit_clp: number;
};
