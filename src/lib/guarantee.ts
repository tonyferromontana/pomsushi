import { supabase } from './supabase';
import type { VehicleType } from './types';

/**
 * Garantía vigente que RUÉ fija para un tipo de vehículo (guarantee_rules, servidor).
 * Solo informativa: el monto de cada reserva queda congelado al solicitarla.
 */
export async function guaranteeForType(type: VehicleType): Promise<number> {
  const { data, error } = await supabase.rpc('guarantee_for_type', { p_vehicle_type: type });
  if (error) throw error;
  return data as number;
}
