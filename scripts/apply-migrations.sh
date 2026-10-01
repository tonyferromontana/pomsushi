#!/usr/bin/env bash
# Aplica las migraciones de supabase/migrations/ que falten en el proyecto de Supabase,
# por HTTPS (Management API), sin conexión directa a la base de datos.
#
# Requiere: SUPABASE_ACCESS_TOKEN y SUPABASE_PROJECT_REF (variables de entorno).
# Uso:      bash scripts/apply-migrations.sh            # aplica las pendientes
#           bash scripts/apply-migrations.sh --dry-run  # solo muestra cuáles faltan
#
# Registra cada migración en supabase_migrations.schema_migrations (la misma tabla que
# usa la CLI de Supabase), así nunca se aplica dos veces y la CLI la reconoce.
set -euo pipefail

: "${SUPABASE_ACCESS_TOKEN:?Falta SUPABASE_ACCESS_TOKEN}"
: "${SUPABASE_PROJECT_REF:?Falta SUPABASE_PROJECT_REF}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/database/query"
DRY="${1:-}"

sql() {
  # $1 = consulta SQL. Devuelve el JSON de la API; falla si la API responde error.
  local body out code
  body="$(jq -Rs '{query: .}' <<<"$1")"
  out="$(mktemp)"
  code="$(curl -sS -o "$out" -w '%{http_code}' -X POST "$API" \
    -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" -H 'Content-Type: application/json' --data-binary "$body")"
  if [[ "$code" != 2* ]]; then
    echo "Error de Supabase (HTTP $code):" >&2
    cat "$out" >&2; echo >&2
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

sql "create schema if not exists supabase_migrations;
     create table if not exists supabase_migrations.schema_migrations (
       version text primary key, statements text[], name text);" >/dev/null

applied="$(sql "select coalesce(json_agg(version), '[]') as v from supabase_migrations.schema_migrations;" | jq -r '.[0].v[]?')"

pending=0
for f in "$ROOT"/supabase/migrations/*.sql; do
  base="$(basename "$f" .sql)"   # 0001_core_schema
  version="${base%%_*}"          # 0001
  name="${base#*_}"
  if grep -qx "$version" <<<"$applied"; then
    echo "✓ $base ya aplicada"
    continue
  fi
  pending=$((pending + 1))
  if [[ "$DRY" == "--dry-run" ]]; then
    echo "• $base pendiente"
    continue
  fi
  echo "→ aplicando $base …"
  # Toda la migración y su registro en una sola transacción: o queda completa o no queda.
  sql "begin;
$(cat "$f")
insert into supabase_migrations.schema_migrations (version, name) values ('$version', '$name');
commit;" >/dev/null
  echo "✓ $base aplicada"
done

echo "Listo. Pendientes encontradas: $pending"
