#!/usr/bin/env bash
# Levanta un Postgres temporal, aplica las migraciones y corre las pruebas.
# Uso: npm run test:db   (requiere Postgres instalado localmente: initdb/pg_ctl)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="${PGBIN:-$(dirname "$(ls /usr/lib/postgresql/*/bin/initdb 2>/dev/null | tail -1)")}"
DATA="$(mktemp -d)"
PORT="${PGPORT_TEST:-54329}"
PGUSER_RUN="${PGUSER_RUN:-postgres}"

cleanup() { su "$PGUSER_RUN" -c "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true; rm -rf "$DATA"; }
trap cleanup EXIT

chown "$PGUSER_RUN" "$DATA"
su "$PGUSER_RUN" -c "$PGBIN/initdb -D $DATA -U postgres --auth=trust" >/dev/null
su "$PGUSER_RUN" -c "$PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null

PSQL="psql -h /tmp -p $PORT -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
$PSQL -f "$ROOT/supabase/tests/supabase_stub.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "→ migración $(basename "$f")"
  $PSQL -f "$f"
done
echo "→ pruebas"
$PSQL -f "$ROOT/supabase/tests/booking_flow.test.sql"
echo "✅ migraciones y pruebas OK"
