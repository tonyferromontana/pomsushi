# CLAUDE.md — Memoria técnica de RUÉ

> Leer este archivo al inicio de cada sesión. Actualizarlo al cerrar cada etapa.
> El dueño del negocio (Antonio) no es programador: explicar en español simple, pasos exactos cuando algo dependa de él.

## 0. Estado actual (2026-09-29)

- El repo `tonyferromontana/pomsushi` no tenía código de Rueda. RUÉ se construyó **desde cero** en esta sesión (el dueño lo pidió explícitamente).
- El archivo `store` (componente web de pedidos de sushi, ajeno a RUÉ) se conserva sin tocar. No borrarlo sin autorización.
- **Código listo para lanzamiento (etapas 1–8 construidas).** Falta lo que depende del dueño: empresa, cuentas (Supabase, Transbank, Expo, Apple, Google), decisiones de negocio, abogado y seguros. Ver `LANZAMIENTO.md`.
- Manual del administrador: `OPERACION.md` (verificaciones, pagos a propietarios, reportes, disputas, reembolsos).
- **Decisiones del dueño (2026-10-01):** todos los tipos de vehículo; precio por días + el arrendador propone hora de entrega y devolución al aceptar; casilla C obligatoria. Pagos: **solo Webpay**, con cuotas. Pendientes: garantía (captura diferida u Oneclick de Transbank, esperando respuestas de Transbank, ver LANZAMIENTO.md) y retracto (a/b con abogado).
- **Términos y Condiciones oficiales = documento del dueño** (`legal/fuente/Terminos_y_condiciones_arriendo_vehiculos.docx`, versión 2026-09-30), convertido a `legal/terminos.md`. Sus notas internas están en `legal/notas-internas.md` (no se publican). La app se alineó con él en la migración 0005.
- Como no existía "Rueda", se usa la marca y la paleta **RUÉ desde el inicio** (no hay rebranding pendiente de nombres internos). Bundle ID provisorio: `cl.rue.app`.

## 1. Qué es RUÉ

- **RUÉ** (ru-é). Sin tildes: `rue`. Antes "Rueda".
- **Marketplace de activos de movilidad**, no una app de arriendo de autos. Conecta a quien tiene vehículos parados con quien los necesita temporalmente (personas, pymes, conductores de apps, empresas).
- Promesa: *Haz producir lo que tienes parado.* Alternativa: *Muévelo. Hazlo producir.*
- "Modo Finde" y "Modo Pega" NO son estructura: existen como **propósitos** (`viaje`, `aplicaciones`, …) y como precio semanal opcional.
- Principio de producto: *¿Esto hace más fácil que un activo parado encuentre a alguien que lo necesita?*

## 2. Stack

Expo SDK 57 (expo 57.0.26, React Native 0.86, React 19.2) · Expo Router 57 (rutas en `src/app/`) · TypeScript strict · Supabase (Postgres + RLS, Auth email/contraseña, Storage, Realtime) · Transbank Webpay Plus (pagos, con cuotas).

Dependencias agregadas (todas funcionan en Expo Go): `@supabase/supabase-js`, `@react-native-async-storage/async-storage` (sesión), `@expo-google-fonts/bricolage-grotesque`, `@expo-google-fonts/dm-sans`, `@react-native-community/datetimepicker`, `expo-image-picker`, `expo-image-manipulator` (compresión de fotos), `@expo/vector-icons`, `expo-notifications` + `expo-device` (push; en Android el push remoto requiere build de EAS, no Expo Go). Sin mapas ni analytics todavía (decisión pendiente con el dueño).

## 3. Estructura

```
src/
  app/                       # Rutas (Expo Router)
    _layout.tsx              # Fuentes, splash, AuthProvider, Stack con rutas protegidas
    sign-in.tsx              # Entrar / crear cuenta (email + contraseña)
    (tabs)/_layout.tsx       # Tabs: Explorar · Reservas · Mis vehículos · Perfil
    (tabs)/index.tsx         # Explorar: tipo, ciudad, fechas, propósito, resultados paginados
    (tabs)/bookings.tsx      # Reservas como arrendatario / como propietario
    (tabs)/garage.tsx        # Mis vehículos: publicar, editar, pausar
    (tabs)/profile.tsx       # Perfil público + datos privados (RUT, teléfono)
    vehicle/[id].tsx         # Ficha: fotos, atributos, cotización del servidor, solicitar
    booking/[id].tsx         # Detalle, acciones por rol, historial, realtime
    chat/[id].tsx            # Chat por reserva (realtime)
    publish.tsx              # Asistente de publicación en 5 pasos (crear / editar) + declaración de papeles al día
    notifications.tsx        # Bandeja de avisos
    verify.tsx               # Subir licencia / cédula (bucket privado documents)
    payout.tsx               # Datos bancarios del propietario
    legal/[doc].tsx          # Términos / Privacidad (accesible sin sesión)
    vehicle-verify.tsx       # Acreditar dominio: Certificado de Anotaciones Vigentes + padrón (cláusula 4)
    handover.tsx             # Acta de entrega / devolución: km, combustible, observaciones, fotos (cláusula 11)
  components/
    ui.tsx                   # Primitivas: Text, Wordmark, Screen, Button, IconButton, Input, FieldButton,
                             # Chip, Segmented, Card, Divider, SectionHeader, Row, Badge, Price, Avatar,
                             # Skeleton, LoadingState, EmptyState, ErrorState, Notice
    VehicleCard.tsx          # Tarjeta de vehículo + VehiclePhoto (placeholder por tipo)
    DateRangeField.tsx       # Selector de fechas (Android: diálogo nativo; iOS: hoja con calendario)
    SetupNeeded.tsx          # Pantalla si falta .env
    forms.tsx                # Checkbox, Stars (reseñas), MenuRow
    ReportSheet.tsx          # Reportar usuario / publicación / reserva (+ bloquear)
  lib/
    supabase.ts              # Cliente (solo EXPO_PUBLIC_*), photoUrl()
    auth.tsx                 # AuthProvider / useAuth
    types.ts                 # Tipos del dominio (reflejan las migraciones)
    catalog.ts               # Tipos de vehículo, propósitos, estados, atributos por tipo
    format.ts                # $ chileno, fechas (solo presentación)
    errors.ts                # friendlyError() / logError()
    useAsync.ts              # Carga con loading / error / reintento
    analytics.ts             # track() — eventos definidos, sin proveedor
    push.ts                  # Registro de token push y apertura de reservas al tocar un aviso
  legal/generated.ts         # GENERADO por scripts/build-legal.mjs (no editar)
  theme.ts                   # Tokens de diseño (única fuente)
legal/                       # FUENTE de Términos y Privacidad (.md) + datos de contacto (sitio.json)
legal/fuente/                # .docx original de los Términos entregado por el dueño
legal/notas-internas.md      # Notas de implementación del modelo de Términos (NO publicar)
docs/                        # Sitio web (GitHub Pages): inicio, términos, privacidad, soporte, eliminar cuenta (GENERADO)
scripts/build-legal.mjs      # npm run legal → regenera src/legal/generated.ts y docs/
supabase/
  migrations/0001_core_schema.sql
  migrations/0002_booking_engine.sql
  migrations/0003_trust_safety_legal.sql   # legal, verificación, reseñas, reportes, bloqueos, avisos, pagos a dueños, borrar cuenta
  migrations/0004_payments_cron_push.sql   # pagos no aprobados, pg_cron (vencimientos), pg_net → push
  migrations/0005_terms_compliance.sql     # cumplimiento de Términos: dominio del vehículo, casillas, actas, bitácora de datos
  migrations/0007_webpay.sql              # pagos Webpay: buy_order, cuotas, tipo de pago, proveedor en confirm/record
  migrations/0006_owner_times_mandatory_consent.sql  # horas propuestas por el arrendador (accept_booking), casilla C obligatoria, Términos 2026-10-01
  functions/                 # Edge Functions (Deno): webpay-create, webpay-return, push-dispatch, delete-account
  functions/_shared/         # http, supabase (admin/usuario), webpay (API Transbank), redirect (+ pruebas)
  config.toml                # verify_jwt por función
  tests/run.sh               # Levanta Postgres temporal, aplica migraciones y corre todos los *.test.sql
  tests/supabase_stub.sql    # Imitación mínima de auth/storage/roles de Supabase (solo pruebas)
  tests/booking_flow.test.sql
  tests/trust_safety.test.sql
  tests/terms_compliance.test.sql
  tests/webpay.test.sql
eas.json                     # Perfiles de build: preview (APK interno) y production (tiendas)
.github/workflows/ci.yml     # CI: legal al día, tsc, lint, pruebas de BD y de Edge Functions
LANZAMIENTO.md               # Lista de tareas del dueño para lanzar
OPERACION.md                 # Manual del administrador (SQL listos para usar)
assets/images/               # icon, splash, android foreground, favicon (PROVISORIOS)
```

## 4. Sistema de diseño (`src/theme.ts`, `src/components/ui.tsx`)

- **Prohibido** escribir colores, fuentes o tamaños sueltos en pantallas. Usar `colors.*`, `type.*`, `space.*`, `radius.*`, `size.*` y las primitivas de `ui.tsx`.
- App oscura (`userInterfaceStyle: dark`). Paleta: asphalt `#101114` (fondo), carbon `#181A1F` (superficies), bone `#F5F3EE` (texto), graphite `#868A93` (secundario), **lime `#D7FF3F`** (CTA principal, estado activo, acento de la É — usar como golpe visual, no inundar). Semánticos: success, warning, error, info, disabled, border, surface.
- Tipografía: Bricolage Grotesque (display/h1/h2/h3/price/priceLarge) + DM Sans (title/body/bodySmall/label/caption/overline). No agregar otras familias.
- Fotos: proporción 4:3 (`photoAspect`), placeholder con ícono del tipo de vehículo, compresión a 1600 px de ancho, JPEG 75 %.
- Logo: `Wordmark` tipográfico provisorio (RU + É en lime). Íconos generados con Bricolage (R + barra lime), **provisorios**. Esperando del dueño: `logo.svg`, `logo-mark.svg`, `icon.png` 1024×1024, `adaptive-icon.png` 1024×1024 (fondo transparente, logo dentro del 66 % central), `splash.png`.
- Microcopy: español de Chile, cercano, claro. "Reservar", "Este vehículo no está disponible para esas fechas".
- Toda pantalla con datos: loading (skeleton o LoadingState), empty (EmptyState), error con reintento (ErrorState), sin errores técnicos crudos (`friendlyError`).

## 5. Modelo de datos (0001)

| Tabla | Qué guarda | Acceso |
|---|---|---|
| `profiles` | nombre visible, avatar, ciudad, verificaciones | lectura: autenticados. Edita el dueño solo `display_name, avatar_url, bio, city` (verificaciones las pone el servidor) |
| `profile_private` | RUT, teléfono, fecha nac., dirección | **solo el propio usuario** |
| `vehicles` | activo multimodal: `vehicle_type`, `status` (borrador/publicado/pausado), datos, `attributes` jsonb, `use_cases`, precio día/semana, garantía, mín. días, `verified` | lectura: publicados o propios. Escribe el propietario (menos `verified`) |
| `vehicle_photos` | ruta en Storage + orden | como el vehículo; la ruta debe partir con el uid |
| `vehicle_blocks` | días bloqueados por el propietario | propietario |
| `bookings` | reserva con montos **congelados** | lectura: participantes. **Sin insert/update desde la app** (solo RPC) |
| `booking_events` | historial de estados (auditoría automática) | lectura: participantes |
| `messages` | chat por reserva, hora del servidor | participantes; se escribe solo como uno mismo |
| `payments` | pagos (sin datos de tarjeta), único por `provider_payment_id` | lectura: participantes; escribe solo servidor |
| `payment_events` | eventos de pago (commit Webpay) sin datos de tarjeta | solo servidor |
| `platform_settings` | comisiones y plazos configurables | solo servidor |

Tablas de 0003/0004: `admins` (solo servidor), `legal_acceptances` (versión aceptada), `verification_requests` (licencia/cédula; aprueba un admin con `review_verification`), `reviews` (una por persona y reserva finalizada, vía `submit_review`), `reports` y `user_blocks` (exigidos por App Store), `notifications` (creadas por triggers; el usuario solo marca `read_at`), `push_tokens`, `payout_accounts` (banco, privado), `payouts` (se crea al finalizar una reserva pagada; admin marca pagado).
RPC nuevas para la app: `accept_terms`, `submit_verification`, `submit_review`, `user_reputation`, `my_bookings`, `booking_vehicle`, `is_admin`, `is_blocked_with`. Solo servidor: `delete_account_data`, `record_payment_status`, `review_verification` (admin o service_role).
`request_booking` y `search_vehicles` fueron reemplazadas en 0003 (bloqueos + licencia obligatoria configurable `require_verified_license`).

0005 (Términos 2026-09-30):
- `vehicles`: + `plate`, `km_per_day` (null = libre), `pickup_location` (referencia, nunca dirección exacta), `fuel_policy` (`mismo_nivel`/`lleno`), `insurance_info`, `verified_until`.
- `vehicle_verifications`: Certificado de Anotaciones Vigentes (≤ `cav_max_age_days`=30 al cargarlo) + padrón en bucket `documents`. Admin aprueba con `review_vehicle_verification` → `verified=true`, `verified_until = hoy + 6 meses`. Cambiar patente/marca/modelo/año quita la verificación (trigger). Cron diario `expire_vehicle_verifications` (7:15) quita vencidas, pausa (si la exigencia está activa) y avisa.
- `require_vehicle_verification` (false por defecto; **true al lanzar**): trigger impide `publicado` sin verificación vigente; `search_vehicles` y `request_booking` la respetan.
- `booking_consents`: casilla A (términos, obligatoria) y C (comunicar datos al arrendador, separada y opcional) por reserva, con versión. **`request_booking` cambió de firma**: `(vehicle, start, end, purpose, message, p_terms_version, p_accept_terms, p_accept_data_sharing)`; exige `p_accept_terms` y la versión vigente.
- `booking_handovers` + bucket privado `handovers` (`<booking_id>/…`, solo participantes y admin), vía `submit_handover`. `transition_booking` exige acta de **entrega** para `en_curso` y de **devolución** para `devuelta`.
- 0006: `bookings.pickup_time` / `return_time` (time). **Aceptar se hace con `accept_booking(id, pickup, return)`** (solo el propietario); `transition_booking(..., 'aceptada')` falla sin horas. Horas congeladas después del pago (trigger). `request_booking` exige `p_accept_data_sharing = true` (casilla C obligatoria). `terms_version` = 2026-10-01. `my_bookings` devuelve las horas.
- `data_disclosures`: bitácora (solo admin escribe) de cada comunicación de datos a arrendador/abogado/autoridad; el titular ve las suyas.

- `vehicle_type`: car, motorcycle, suv, pickup, van, cargo_van, truck, minibus, trailer, special. Atributos por tipo en `attributes` (jsonb) validados por `validate_vehicle_attributes()` (claves permitidas y rangos). El formulario por tipo está en `ATTRIBUTE_FIELDS` (`src/lib/catalog.ts`). Para un atributo nuevo: agregar la clave en una **migración nueva** (reemplazando la función) y en `catalog.ts`.
- Storage: `vehicle-photos` (lectura pública; cada usuario escribe solo en `<uid>/…`), `documents` (privado; solo `<uid>/…`).
- Realtime: `messages` y `bookings` en la publicación `supabase_realtime` (Realtime respeta RLS).
- Fechas de reserva: `[start_date, end_date)` → días = fin − inicio. Restricción `exclude` impide dos reservas activas cruzadas del mismo vehículo.

## 6. Precios y máquina de estados (0002)

**Precio (solo `compute_booking_price`)**: arriendo = días × precio día; si hay precio semanal y ≥7 días: min(normal, semanas × semanal + resto × día). `renter_fee = arriendo × renter_service_fee_pct`, `owner_commission = arriendo × owner_commission_pct`, `total = arriendo + renter_fee`, `owner_payout = arriendo − comisión`. La garantía se guarda aparte (no está incluida en el total; cómo se cobra/retiene es decisión pendiente). **Los % iniciales son 0: los define el dueño del negocio** en `platform_settings`.

**Estados**

```
solicitada → aceptada → confirmada → en_curso → devuelta → finalizada
```

| Desde | Hacia | Quién |
|---|---|---|
| solicitada | aceptada / rechazada | propietario (al aceptar, las otras solicitudes cruzadas pasan a rechazada) |
| solicitada | cancelada | arrendatario |
| solicitada / aceptada | vencida | servidor (`expire_stale_bookings`, cron) |
| aceptada | confirmada | **solo** `confirm_booking_payment` (commit Webpay, service_role) |
| aceptada | cancelada | cualquiera de los dos |
| confirmada | en_curso | propietario, desde la fecha de inicio (hora Chile) |
| confirmada | cancelada | permitido en el grafo, **no expuesto a la app** (requiere política de reembolso) |
| en_curso | devuelta | propietario |
| devuelta | finalizada | propietario |
| en_curso / devuelta | disputada | cualquiera de los dos |
| disputada | finalizada / cancelada | solo servidor/soporte |

- `booking_transition_allowed()` + trigger `enforce_booking_transition` rechazan **cualquier** salto inválido, incluso del servidor, y bloquean cambios de montos/fechas/partes.
- RPC para la app: `search_vehicles`, `quote_booking`, `request_booking`, `transition_booking`. Solo servidor: `confirm_booking_payment` (idempotente; devuelve `confirmed` | `already_confirmed` | `amount_mismatch` | `not_payable`), `expire_stale_bookings`.
- Plazos: `request_expiry_hours` (24), `payment_expiry_hours` (24), `max_booking_days` (90).
- `expire_stale_bookings()` corre cada 10 minutos con pg_cron (0004).
- Avisos: triggers `notify_booking_change` / `notify_new_message` (máx. 1 aviso de mensajes cada 10 min por reserva) → `notifications` → trigger `dispatch_push` (pg_net) → Edge Function `push-dispatch` (Expo Push). Requiere `platform_settings.supabase_url`.

**Pagos (Webpay Plus, Transbank)** — decisión del dueño 2026-10-01: solo Webpay (Mercado Pago eliminado; queda en el historial de git).
1. App → `webpay-create` (JWT): valida arrendatario, reserva `aceptada` y no vencida; monto = `bookings.total_clp`; crea transacción (`buy_order` ≤ 26 caracteres, `session_id` = id de reserva) y guarda `payments` (`preference_id` = token, `status` = created).
2. App abre `url?token_ws=token` con `WebBrowser.openAuthSessionAsync`. En el formulario de Webpay la persona elige crédito (con **cuotas**, según contrato del comercio y banco), débito o prepago.
3. Transbank vuelve a `webpay-return` (sin JWT; GET o POST, `token_ws` o `TBK_TOKEN` si anuló). El **servidor hace commit** con Transbank (si falla, consulta estado), valida `AUTHORIZED` + `response_code = 0` + monto + orden, y llama `confirm_booking_payment(..., 'webpay')`. Si la reserva ya no era pagable, el monto no calza o es un **pago doble**, **anula automáticamente** (refund) y registra `refunded`. Guarda `payment_type` e `installments`. Redirige a `rue://pago?status=approved|rejected|cancelled|refunded|error`.
4. No hay webhook: sin commit, Transbank reversa sola la transacción. Ambiente `test` usa credenciales públicas de integración si no hay `TBK_COMMERCE_CODE`/`TBK_API_KEY`.

## 7. Reglas inviolables

1. Dinero y estados en el servidor. La app solo muestra lo que devuelven las RPC.
2. Comisiones configurables en `platform_settings`. Nunca inventar porcentajes.
3. RLS en toda tabla nueva. Datos sensibles (RUT, teléfono, dirección, licencia, cédula, documentos, banco, info financiera) nunca públicos. Storage con policies.
4. Migraciones: siempre un archivo **nuevo** (`0003_…`). No editar 0001/0002 una vez aplicadas en Supabase. Correr `npm run test:db` y agregar pruebas al cambiar el esquema.
5. Pagos: transacción creada en backend; confirmación solo por commit servidor-a-servidor con Transbank (validar estado, código, monto y orden); idempotencia; anulación automática de pagos no correspondientes; test/prod separados; nunca datos de tarjeta.
6. Secretos: en la app solo `EXPO_PUBLIC_*`. Service role, token de MP y secretos de webhook solo como secrets de Edge Functions.
7. Garantías, vencimientos y notificaciones corren en el servidor (cron), nunca dependen de abrir la app.
8. Nada de `catch {}` silencioso: `logError()` en la app, logs sin secretos en el backend.
9. Después de cada cambio: `npx tsc --noEmit` y `npx expo lint` sin errores antes de decir "listo".
10. Cambios incrementales; no borrar sin autorización.

## 8. Comandos

```bash
npm install
npx tsc --noEmit                     # obligatorio
npx expo lint                        # obligatorio
npm run test:db                      # migraciones + pruebas de seguridad y reservas (Postgres local)
npm run test:functions               # pruebas + tipos de Edge Functions (Deno; npx -y deno si no está instalado)
npm run legal                        # regenera textos legales (app + docs/) desde legal/*.md
npx expo start                       # abrir con Expo Go (QR)
npx expo start --tunnel              # si el celular no está en la misma red
npx expo start --clear               # después de cambiar .env
npx expo install <paquete>           # nunca npm install directo para libs nativas
```

En el contenedor de Claude Code (nube) la API de Expo está bloqueada por el proxy: usar `EXPO_OFFLINE=1` delante de `npx expo install|start|export|lint`. Para ver pantallas: `npx expo export --platform web` + Playwright con respuestas de Supabase simuladas.

## 9. Variables de entorno

App (`.env`, ver `.env.example`, nunca se sube a git):
- `EXPO_PUBLIC_SUPABASE_URL`
- `EXPO_PUBLIC_SUPABASE_ANON_KEY` (anon `eyJ…` o publishable `sb_publishable_…`)

Servidor (secrets de Edge Functions, `supabase secrets set`): `TBK_ENVIRONMENT` (`test`/`prod`), `TBK_COMMERCE_CODE`, `TBK_API_KEY` (solo producción). `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` los inyecta Supabase.

Base de datos (`platform_settings`, ver OPERACION.md): `supabase_url` (activa push), `internal_webhook_secret` (se genera solo), comisiones, plazos, `terms_version`, `require_verified_license`.

App: `extra.eas.projectId` en app.json lo crea `eas init` (sin él no hay token push; la bandeja igual funciona).

Acceso para que Claude despliegue (opcional, ver LANZAMIENTO.md Fase 3): variables `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `EXPO_TOKEN`, `TBK_COMMERCE_CODE`, `TBK_API_KEY` y red a supabase.com, *.supabase.co, expo.dev, api.expo.dev, exp.host, webpay3gint.transbank.cl, webpay3g.transbank.cl.

Despliegue (Supabase CLI):
```bash
npx supabase link --project-ref $SUPABASE_PROJECT_REF
npx supabase db push                          # aplica migraciones pendientes
npx supabase functions deploy webpay-create webpay-return push-dispatch delete-account
npx supabase secrets set TBK_ENVIRONMENT=test          # prod: + TBK_COMMERCE_CODE=... TBK_API_KEY=...
```
Builds (EAS): `npx eas-cli init` (crea projectId), `npx eas-cli build --profile preview|production --platform all`, `npx eas-cli submit --platform ios|android`.

Configuración de Supabase para pruebas: Authentication → Sign In / Providers → Email → desactivar "Confirm email" facilita probar con cuentas falsas (reactivar antes de producción).

## 10. Estado por módulo

| Módulo | Estado |
|---|---|
| Base de datos 0001–0004 + RLS + Storage + cron + push | ✅ probado localmente (`npm run test:db`, 2 archivos de pruebas); ⏳ aplicar en Supabase real |
| Auth email/contraseña + aceptación de términos + mayoría de edad | ✅ |
| Explorar, ficha, cotización, solicitud | ✅ |
| Publicar / editar / pausar + declaración de papeles | ✅ |
| Reservas por rol + historial + realtime | ✅ |
| Pago Webpay (crear, commit en servidor, cuotas, anulación automática, pago doble) | ✅ código + pruebas; ⏳ probar en integración de Transbank (desde el celular del dueño) |
| Avisos en la app + push | ✅ bandeja; ⏳ push requiere `supabase_url`, `eas init` y build EAS |
| Verificación de licencia/cédula (revisión manual de admin) | ✅ |
| Reseñas y reputación real | ✅ |
| Reportar y bloquear | ✅ |
| Eliminar cuenta (app + web) | ✅ |
| Datos bancarios y pagos a propietarios (manual, ver OPERACION.md) | ✅ |
| Términos y Privacidad (borradores) + sitio web docs/ | ✅ borrador; ⏳ revisión de abogado y datos de empresa |
| EAS (eas.json, app.json) | ✅ config; ⏳ cuentas Expo/Apple/Google del dueño |
| CI GitHub Actions | ✅ |
| Chat | ✅ (sin "leído") |
| Bloqueo de fechas por el propietario (UI) | ⏳ backlog (tabla lista) |
| Verificación de dominio del vehículo (CAV + padrón, 6 meses) | ✅ (activar `require_vehicle_verification` al lanzar) |
| Actas de entrega y devolución con fotos | ✅ |
| Casillas A/C por reserva + bitácora de datos | ✅ |
| Garantía con tarjeta de crédito (cláusulas 8–10) | ⏳ captura diferida u Oneclick de Transbank; esperando respuestas de Transbank |
| Horas de entrega/devolución propuestas por el arrendador (cláusula 6) | ✅ precio por días |
| Personas jurídicas como arrendador (cláusula 3–4) | ⏳ backlog |
| Conductores adicionales (cláusula 5) | ⏳ backlog (hoy: solo el arrendatario conduce) |
| Mapa, analytics | ⏳ decisión del dueño |
| Logo definitivo | ⏳ archivos del dueño |

## 11. Deuda técnica y riesgos conocidos

| Nivel | Hallazgo |
|---|---|
| Crítico (negocio) | Seguros: no hay cobertura definida para daños durante el arriendo. No lanzar al público sin resolverlo. |
| Importante | Comisión y cargo de servicio en 0 %: definir antes de cobrar. |
| Importante | Términos ampliados por Claude a todos los tipos de vehículo (decisión del dueño): falta revisión del abogado. |
| Importante | Garantía por bloqueo de cupo (Términos 8–10) pendiente: Webpay captura diferida (plazo de captura limitado) u Oneclick. |
| Importante | Derecho de retracto (10 días, cláusula 20) y política de cancelación no implementados en la app (cancelación de reservas pagadas es manual). Esperando decisión (a) dar retracto o (b) excluirlo con aviso. |
| Importante | Casilla C obligatoria: el propio modelo de Términos advierte no condicionar el servicio a consentimientos innecesarios; validar con abogado. |
| Importante | Política de cancelación con reembolso no definida: `confirmada → cancelada` no se ofrece en la app; reembolsos manuales en el Portal de Transbank (OPERACION.md). |
| Importante | Garantía: se muestra como "se coordina con el propietario"; no se cobra por la app. |
| Importante | Pagos a propietarios manuales (transferencia + marcar en SQL). Webpay no reparte pagos a terceros. |
| Importante | Webpay no probado contra Transbank real desde este entorno (proxy bloquea transbank.cl). El método de redirección GET `url?token_ws=` y el retorno GET/POST deben verificarse en integración. |
| Mejora | Al guardar fotos se borran y reinsertan las filas de `vehicle_photos`; pasar a RPC transaccional. |
| Mejora | Al eliminar cuenta, las fotos de vehículos borrados quedan en Storage (no son datos personales). Limpiar con tarea periódica. |
| Mejora | `messages.read_at` no se actualiza (sin "leído"). |
| Mejora | Tipos de BD a mano (`src/lib/types.ts`); generar con `supabase gen types`. |
| Mejora | Repo público: el código es visible (no hay secretos). GitHub Pages gratis requiere repo público. |

## 12. Etapas (detenerse al final de cada una y esperar visto bueno)

0. Auditoría + CLAUDE.md — ✅
1. RUÉ corriendo en el celular con Expo Go — ✅ código; ⏳ Supabase + `.env` del dueño
2. Rebranding — ✅ (se partió como RUÉ); ⏳ logo/íconos definitivos
3. Arquitectura multimodal — ✅ `vehicle_type` + `attributes`
4. Pagos Webpay — ✅ código y pruebas; ⏳ desplegar y probar en integración; afiliación Transbank del dueño
5. Reserva completa con dos cuentas — ⏳ prueba manual del dueño (Fase 4 de LANZAMIENTO.md)
6. Cron y notificaciones — ✅; garantías ⏳ decisión de negocio
7. Calidad — ✅ tsc, lint, CI, pruebas de BD y funciones
8. EAS / TestFlight — ✅ configuración; ⏳ cuentas del dueño

Preguntar al dueño solo por negocio, dinero, marca, legal, servicios pagados, credenciales, producción o borrados. Lo técnico y reversible lo decide Claude.
