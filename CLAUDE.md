# CLAUDE.md — Memoria técnica de RUÉ

> Leer este archivo al inicio de cada sesión. Actualizarlo al cerrar cada etapa.
> El dueño del negocio (Antonio) no es programador: explicar en español simple, pasos exactos cuando algo dependa de él.

## 0. Estado actual (2026-09-29)

- El repo `tonyferromontana/pomsushi` no tenía código de Rueda. RUÉ se construyó **desde cero** en esta sesión (el dueño lo pidió explícitamente).
- El archivo `store` (componente web de pedidos de sushi, ajeno a RUÉ) se conserva sin tocar. No borrarlo sin autorización.
- **Código listo para lanzamiento (etapas 1–8 construidas).** Falta lo que depende del dueño: empresa, cuentas (Supabase, Transbank, Expo, Apple, Google), decisiones de negocio, abogado y seguros. Ver `LANZAMIENTO.md`.
- Manual del administrador: `OPERACION.md` (verificaciones, pagos a propietarios, reportes, disputas, reembolsos).
- **Configuración económica del MVP implementada (migración 0008, 2026-10-01):** comisiones versionadas 15 %/8 %, garantías por tipo fijadas por RUÉ, snapshot de precio por reserva, ledger inmutable, GMV/take rate, payouts T+2 con estados, domain events. **IVA pendiente de contador** (no se asume neto ni bruto). Ver §6 y §13.17.
- **ETAPA ACTUAL: beta privada (2026-10-01).** Sin funcionalidades nuevas. El dueño sigue `BETA.md` (cuentas Supabase/Expo/Apple + variables + red en el entorno). Al abrir una sesión con esas variables, ejecutar el **runbook de §15**.
- **Marketplace transaccional completo (migración 0009, 2026-10-01): ver §14.** Negociación tipo inDrive (ofertas con mínimo de RUÉ, 3 rondas), datos de contacto ocultos y señales de pago por fuera marcadas para revisión, contrato digital con hash, check-in/out confirmado por ambas partes con daños estructurados, extensiones pagadas por Webpay, trust layer y relación repetida en el snapshot.
- **Arquitectura de negocio y salida (2026-10-01): ver §13.** Es la definición vigente del modelo económico y reemplaza cualquier supuesto anterior contradictorio. Comisión propietario **15 %**, fee arrendatario **8 %**, garantía la determina RUÉ (no el propietario), payout T+2 días hábiles. Contradicciones con el código actual y plan: §13.17.
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

Dependencias agregadas (todas funcionan en Expo Go): `@supabase/supabase-js`, `@react-native-async-storage/async-storage` (sesión), `@expo-google-fonts/bricolage-grotesque`, `@expo-google-fonts/dm-sans`, `@react-native-community/datetimepicker`, `expo-image-picker`, `expo-image-manipulator` (compresión de fotos), `@expo/vector-icons`, `expo-notifications` + `expo-device` (push; en Android el push remoto requiere build de EAS, no Expo Go). `expo-location` (solo primer plano, ubicación aproximada; Android sin FINE ni BACKGROUND). Sin mapa embebido ni analytics externo (decisión del dueño).

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
    payout.tsx               # Datos bancarios del propietario (estado de cada pago: en booking/[id])
    legal/[doc].tsx          # Términos / Privacidad (accesible sin sesión)
    vehicle-verify.tsx       # Acreditar dominio: Certificado de Anotaciones Vigentes + padrón (cláusula 4)
    handover.tsx             # Acta de entrega / devolución: km, combustible, daños por zona, observaciones, fotos (cláusula 11)
  components/
    ui.tsx                   # Primitivas: Text, Wordmark, Screen, Button, IconButton, Input, FieldButton,
                             # Chip, Segmented, Card, Divider, SectionHeader, Row, Badge, Price, Avatar,
                             # Skeleton, LoadingState, EmptyState, ErrorState, Notice
    VehicleCard.tsx          # Tarjeta de vehículo + VehiclePhoto (placeholder por tipo)
    DateRangeField.tsx       # Selector de fechas (Android: diálogo nativo; iOS: hoja con calendario)
    SetupNeeded.tsx          # Pantalla si falta .env
    forms.tsx                # Checkbox, Stars (reseñas), MenuRow
    ReportSheet.tsx          # Reportar usuario / publicación / reserva (+ bloquear)
    ReviewsList.tsx          # Reseñas recibidas (estrellas + comentario): en la ficha (del vehículo) y en la reserva (de la otra parte)
    booking/NegotiationCard.tsx  # Ofertas y contraofertas (counter_offer / accept_offer / accept_booking)
    booking/ExtensionCard.tsx    # Pedir, aprobar y pagar extensiones
    booking/AgreementCard.tsx    # Contrato digital y anexos (hash)
  lib/
    supabase.ts              # Cliente (solo EXPO_PUBLIC_*), photoUrl()
    auth.tsx                 # AuthProvider / useAuth
    types.ts                 # Tipos del dominio (reflejan las migraciones)
    catalog.ts               # Tipos de vehículo, propósitos, estados, atributos por tipo
    format.ts                # $ chileno, fechas (solo presentación)
    errors.ts                # friendlyError() / logError()
    useAsync.ts              # Carga con loading / error / reintento
    analytics.ts             # track(): consola + log_event() para vehicle_viewed / checkout_started
    guarantee.ts             # guaranteeForType(): garantía vigente de RUÉ por tipo (solo informativa)
    maps.ts                  # openInMaps(): abre Apple/Google Maps con la referencia de entrega (sin API key, sin GPS)
    location.ts              # getApproxLocation(): permiso + ubicación redondeada a ~1 km (solo cuando la persona lo pide)
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
  migrations/0006_owner_times_mandatory_consent.sql  # horas propuestas por el arrendador (accept_booking), casilla C obligatoria, Términos 2026-10-01
  migrations/0007_webpay.sql              # pagos Webpay: buy_order, cuotas, tipo de pago, proveedor en confirm/record
  migrations/0008_economics.sql           # config económica versionada, guarantee_rules, snapshot, ledger, payouts T+2, domain_events, métricas
  migrations/0009_transaction_lifecycle.sql  # ofertas, contacto oculto/moderación, contrato digital, check-in/out, extensiones, trust
  migrations/0010_booking_vehicle_pickup.sql # booking_vehicle() devuelve pickup_location (botón "Ver en el mapa")
  migrations/0011_nearby_search.sql        # "Cerca de mí": vehicle_locations (punto ~1 km, ilegible), search_vehicles con distance_km
  functions/                 # Edge Functions (Deno): webpay-create, webpay-return, push-dispatch, delete-account
  functions/_shared/         # http, supabase (admin/usuario), webpay (API Transbank), redirect (+ pruebas)
  config.toml                # verify_jwt por función
  tests/run.sh               # Levanta Postgres temporal, aplica migraciones y corre todos los *.test.sql
  tests/supabase_stub.sql    # Imitación mínima de auth/storage/roles de Supabase (solo pruebas)
  tests/booking_flow.test.sql
  tests/trust_safety.test.sql
  tests/terms_compliance.test.sql
  tests/webpay.test.sql
  tests/economics.test.sql                # ejemplo 100.000 → GMV 100.000, fees 15.000/8.000, cobro 108.000, take rate 23 %
  tests/lifecycle.test.sql                # negociación 3 rondas, mínimo, chat oculto, contrato, check-in, extensión, payout
  tests/nearby.test.sql                   # cerca de mí: redondeo, nadie lee ubicaciones, distancia entera, sin coordenadas en eventos
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

Tablas de 0003/0004: `admins` (solo servidor), `legal_acceptances` (versión aceptada), `verification_requests` (licencia/cédula; aprueba un admin con `review_verification`), `reviews` (una por persona y reserva finalizada, vía `submit_review`), `reports` y `user_blocks` (exigidos por App Store), `notifications` (creadas por triggers; el usuario solo marca `read_at`), `push_tokens`, `payout_accounts` (banco, privado), `payouts` (desde 0008: se crea al devolver, elegible a T+2 días hábiles; admin marca pagado con `mark_payout_paid`).
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

**Precio (solo `compute_booking_price`, 0008)**: arriendo base = días × precio día; si hay precio semanal y ≥7 días: min(normal, semanas × semanal + resto × día). Extras = 0 (aún no existen). `gmv = base + extras`. Tasas desde `active_economic_config()` (tabla `economic_config_versions`, inmutable, la última con `effective_from <= now`): `owner_commission = round(gmv × owner_fee_rate)`, `renter_fee = round(gmv × renter_service_fee_rate)`, `total (cobrado) = gmv + renter_fee`, `owner_payout = gmv − owner_commission`, `platform_gross_revenue = owner_commission + renter_fee`. Garantía = `resolve_guarantee(tipo, contexto)` desde `guarantee_rules` (inmutable; `conditions` jsonb para reglas futuras, hoy solo `{}`), guardada en `bookings.deposit_clp` — **no** está en el total, ni en GMV ni en ingresos. Cada reserva guarda `pricing_snapshot` (insumos, tasas, versión, regla de garantía, resultados), `economic_config_id` y `guarantee_rule_id`; todo congelado por `enforce_booking_transition`.
- Config vigente: `mvp-2026-10-01` = 15 % / 8 % / `tax_treatment = pending_accountant` / payout 2 días hábiles. Cambios: `publish_economic_config(...)` y `publish_guarantee_rule(...)` (admin o service_role, motivo obligatorio). Si `tax_treatment` ≠ pending, `compute_booking_price` falla a propósito hasta implementar el cálculo de IVA en una migración nueva.
- `owner_commission_pct`/`renter_service_fee_pct` **ya no existen** en `platform_settings` (una sola fuente de verdad). Cambios a `platform_settings` quedan en `platform_settings_history`.
- `vehicles.deposit_clp` es obsoleta: el propietario ya no tiene permiso de escribirla.
- **Ledger** `ledger_entries` (inmutable, solo servidor; `idempotency_key` única): se escribe por triggers — pago aprobado → `payment_received`; reserva `confirmada` → `rental_base`, `rental_extra`, `owner_fee`, `renter_service_fee`, `owner_payout_due`; cancelada tras pagar → las mismas con signo negativo; pago `refunded` → `refund`; `mark_payout_paid` → `owner_payout_paid`; admin: `record_manual_refund`, `record_processing_cost`. Columnas `gross_amount_clp` (lo que se mueve), `net_amount_clp`/`tax_amount_clp` (NULL mientras el IVA está pendiente), `counts_as_gmv` (solo rental_*), `counts_as_revenue` (solo fees), garantía nunca GMV ni ingreso (constraints).
- **Reporting** (solo admin/service_role): vista `booking_financials` (rental_base_amount, rental_extras, gmv_amount, owner_fee, renter_service_fee, charged_amount, guarantee_amount, tax_amount, payment_processing_cost, refunds, owner_payout, platform_gross_revenue, platform_net_revenue — neto NULL hasta conocer IVA y costo) y `marketplace_summary(desde, hasta)` (GMV e ingresos desde el ledger, take rate, búsquedas y sin resultado, reservas).
- **Payouts**: estados `pending → eligible → scheduled → paid` + `held`, `failed`. Se crean al pasar a `devuelta` (o `finalizada` desde una disputa) con `eligible_on = add_business_days(fecha devolución CL, payout_delay de la reserva)` (salta fines de semana y `business_holidays`). Cron horario `promote_eligible_payouts()`. `disputada` → `held/open_dispute`; cancelada tras pagar → `held`. Admin: `schedule_payout`, `mark_payout_paid`, `hold_payout`, `release_payout`, `mark_payout_failed`. El propietario ve su payout (RLS) en el detalle de la reserva.
- **Domain events** `domain_events` (solo servidor): triggers en profiles, vehicles, bookings, payments, payouts + `search_performed` desde `search_vehicles` (primera página, con `result_count`/`zero_result`). La app solo puede enviar `vehicle_viewed` y `checkout_started` vía `log_event()`.

**Ciclo transaccional (0009)** — ver §14 para el principio de producto.
- `price_booking(vehicle, start, end, agreed_daily)` es el cálculo único (compute_booking_price lo envuelve). `price_guidance()` da publicado/recomendado/mínimo desde `offer_rules` (versionada, inmutable; MVP provisorio 82 % / 95–105 % / redondeo $1.000 / 3 rondas / 24 h). `quote_booking(…, p_offer_daily_clp)` devuelve la guía **sin el mínimo**.
- `request_booking(…, p_offer_daily_clp)`: oferta < publicado → valida mínimo, precio a la oferta, crea `booking_offers` ronda 1 (con `max_rounds`). Oferta ≥ publicado → reserva normal. Guarda `pricing_snapshot.relationship.repeat_pair_completed` (reservas finalizadas previas de la pareja) y oculta contacto en el mensaje.
- `counter_offer(booking, monto, horas?)` (quien recibe la oferta pendiente; el propietario incluye horas), `accept_offer(booking)` (arrendatario acepta contraoferta → `aceptada` con esas horas), `accept_booking(booking, horas)` (propietario; acepta la oferta pendiente del arrendatario). Una sola oferta `pending` por reserva (índice único). Rechazar/cancelar/vencer la reserva cierra las ofertas (trigger).
- **Re-precio** solo con `reprice_booking()` y `bookings.status = 'solicitada'` (flag `rue.reprice`); después de aceptar los montos quedan congelados. `transition_booking` ya no acepta: se acepta con `accept_booking`/`accept_offer` (`finalize_acceptance`).
- **Contacto**: `contact_signals()`/`mask_contact_data()`. Trigger en `messages`: antes de `confirmada` oculta teléfonos/correos/links (`moderation = {masked:true}` visible para las partes); siempre marca señales de pago por fuera en `message_flags` (solo admin) + evento `off_platform_signal`. Publicaciones (título, descripción, lugar) y perfiles (nombre, bio) rechazan teléfonos/correos/links. Nunca se bloquea un mensaje.
- **Check-in/out**: `booking_handovers` + `damages` (jsonb `[{zone, description, photo_path?}]`, validado), `latitude/longitude` (opcionales, la app aún no los envía), `owner/renter_confirmed_at`, `analysis`/`analysis_status` (futuro: damage_detection, photo_comparison, odometer_ocr). `submit_handover(…, p_damages, p_lat, p_lng)` confirma por su autor; `confirm_handover(id)` la otra parte. `en_curso` exige acta de entrega confirmada por **ambos**; `devuelta` exige acta de devolución con confirmación del propietario. `handover_comparison(booking)`: km recorridos vs permitidos, combustible, daños nuevos por zona.
- **Contrato digital**: `booking_agreements` (inmutable, participantes leen) se genera al pasar a `confirmada` (v1 `contract`) y por cada extensión pagada (`extension_addendum`), con `content` jsonb y `content_sha256`. Partes con nombre visible; RUT/datos legales los resguarda RUÉ. Protección: `status = not_offered`.
- **Extensiones**: `booking_extensions` (montos y snapshot inmutables): `request_extension(booking, nueva_fin)` (arrendatario, reserva `confirmada`/`en_curso`, disponibilidad, tarifa diaria del contrato, fees de la config vigente) → `respond_extension` (propietario) → pago Webpay (`webpay-create` con `extension_id`; `payments.extension_id`) → `confirm_extension_payment` (service_role; mismos códigos que el pago de reserva; mueve `bookings.end_date` con flag `rue.extension`). Ledger `extension:<id>:…`; payout incluye extensiones pagadas; vencen con `expire_stale_bookings`; se cierran si la reserva termina.
- **Cerca de mí (0011)**: `vehicle_locations` (lat/lng `numeric(6,2)` ≈ 1,1 km, RLS sin policies: nadie la lee); `set_vehicle_location` / `clear_vehicle_location` / `vehicle_has_location` (solo el dueño); `search_vehicles(…, p_near_lat, p_near_lng, p_radius_km)` devuelve `distance_km` entero (mín. 1) y ordena por distancia; `search_performed` registra `near_me`/`radius_km`, nunca coordenadas; `delete_account_data` borra los puntos.
- **Trust**: `user_trust(user)` (verificaciones, completados como propietario/arrendatario, rating, cancelaciones 12 m, mediana de respuesta, tasa de respuesta; sin disputas) y `vehicle_trust(vehicle)` (verificado, completados, rating; utilización 90 d, disputas y próxima reserva solo para el propietario/admin).

**Estados**

```
solicitada → aceptada → confirmada → en_curso → devuelta → finalizada
```

| Desde | Hacia | Quién |
|---|---|---|
| solicitada | aceptada | propietario con `accept_booking` o arrendatario con `accept_offer` (las otras solicitudes cruzadas pasan a rechazada) |
| solicitada | rechazada | propietario |
| solicitada | cancelada | arrendatario |
| solicitada / aceptada | vencida | servidor (`expire_stale_bookings`, cron) |
| aceptada | confirmada | **solo** `confirm_booking_payment` (commit Webpay, service_role) |
| aceptada | cancelada | cualquiera de los dos |
| confirmada | en_curso | propietario, desde la fecha de inicio (hora Chile), con acta de entrega confirmada por ambos |
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
6. Secretos: en la app solo `EXPO_PUBLIC_*`. Service role y claves de Transbank (`TBK_*`) solo como secrets de Edge Functions.
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
bash scripts/apply-migrations.sh     # aplica migraciones pendientes por HTTPS (Management API); --dry-run para ver
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
| Reseñas y reputación real | ✅ se dejan al finalizar (1–5 estrellas + comentario) y se muestran en la ficha del vehículo y en la reserva |
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
| Garantía con tarjeta de crédito (cláusulas 8–10) | ✅ monto por tipo fijado por RUÉ (`guarantee_rules`); ⏳ cobro/bloqueo: captura diferida u Oneclick, esperando respuestas de Transbank |
| Configuración económica (15 %/8 % versionada, snapshot, ledger, GMV/take rate, payouts T+2, domain events) | ✅ 0008 + pruebas; ⏳ IVA (contador) |
| Horas de entrega/devolución propuestas por el arrendador (cláusula 6) | ✅ precio por días |
| Negociación tipo inDrive (ofertas, mínimo de RUÉ, 3 rondas) | ✅ 0009 + UI; ⏳ dueño confirma números (provisorios) |
| Contacto oculto + moderación de pagos por fuera | ✅ 0009 (revisión manual en OPERACION.md 5 b) |
| Contrato digital con hash + anexos | ✅ 0009 |
| Check-in/out confirmado por ambos + daños por zona + comparación | ✅ 0009; ⏳ ubicación GPS y análisis de fotos (futuro) |
| Extensiones con pago Webpay | ✅ 0009 + webpay-create/return; ⏳ probar en integración de Transbank |
| Trust layer (user_trust, vehicle_trust) | ✅ 0009 (ficha usa user_trust) |
| Protección / seguro como producto | ⏳ aseguradora (no se afirma cobertura) |
| RUÉ Pro / Fleet (organizaciones) | ⏳ arquitectura descrita en §14; sin tablas aún |
| Personas jurídicas como arrendador (cláusula 3–4) | ⏳ backlog |
| Conductores adicionales (cláusula 5) | ⏳ backlog (hoy: solo el arrendatario conduce) |
| Mapa | ✅ nivel 1: botón "Ver en el mapa" (ficha y reserva) que abre Apple/Google Maps con la referencia de entrega, sin clave ni costo; ⏳ nivel 2 (mapa dentro de la app con react-native-maps + clave de Google Maps con facturación): decisión del dueño, después de la beta |
| Cerca de mí (0011) | ✅ el arrendatario busca por distancia (radio 10/25/50 km, ubicación redondeada y no guardada); el propietario marca opcionalmente un punto aproximado (~1 km) que nadie puede leer, solo se ve "a X km" |
| Analytics externo | ⏳ decisión del dueño |
| Logo definitivo | ⏳ archivos del dueño |

## 11. Deuda técnica y riesgos conocidos

| Nivel | Hallazgo |
|---|---|
| Crítico (negocio) | Seguros: no hay cobertura definida para daños durante el arriendo. No lanzar al público sin resolverlo. |
| Importante | IVA de comisión y cargo de servicio pendiente de contador: `tax_treatment = pending_accountant`, impuestos e ingreso neto en NULL, cláusula 7 con marcador. |
| Importante | Ingreso reconocido al confirmar el pago (y revertido si se cancela después): validar criterio con el contador. |
| Mejora | Feriados movibles de Chile: el admin los agrega en `business_holidays` cada año. |
| Importante | Mínimo de precio fijado por la plataforma entre particulares: validar con abogado (libre competencia). Números de `offer_rules` provisorios. |
| Mejora | Detección de contacto por expresiones regulares: puede tener falsos positivos/negativos; por eso solo oculta antes del pago y marca para revisión humana. |
| Mejora | Con varias ofertas abiertas de distintos arrendatarios para las mismas fechas, aceptar una rechaza las demás (trigger); no hay subasta. |
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

## 13. Arquitectura de negocio y salida (Business & Exit Architecture) — definición del dueño, 2026-10-01

> Esta sección es la **definición vigente** del modelo económico de RUÉ y **reemplaza cualquier supuesto anterior contradictorio**. Es la **arquitectura objetivo**: no se implementa todo ahora. Se construyen solo las capas necesarias para la etapa actual **sin cerrar el camino** hacia esta arquitectura. No hacer rewrites generales.

### 13.1 Objetivo estratégico
- RUÉ se construye como compañía tecnológica **asset-light, escalable y potencialmente adquirible**. No optimizar por cantidad de features.
- Optimizar arquitectura, datos y producto alrededor de: **GMV, ingresos netos, take rate, liquidez, utilización, repetición, retención de supply, unit economics, datos propietarios y efectos de red**.
- RUÉ **no** es una rentadora ni compra flota. Es la infraestructura que conecta capacidad de movilidad ociosa con demanda temporal.
- Concepto: *"Transformamos activos de movilidad detenidos en activos productivos."* Promesa: *"Haz producir lo que tienes parado."*

### 13.2 Unidad del marketplace
- Entidad principal: `vehicle` / `mobility_asset`. Nunca diseñar alrededor de `car`.
- Tipos: car, motorcycle, suv, pickup, van, cargo_van, minibus, truck, trailer, special. **Categorías extensibles**: preferir tabla de categorías (o equivalente) por sobre enums rígidos cuando dé más flexibilidad.

### 13.3 Comisión propietario
- MVP: **15 %**, descontado del precio base de arriendo.
- Nunca en el frontend ni repetido en varias Edge Functions: **configuración central server-side**.
- Preparar tasas por: standard owner (15 %), pro owner, fleet owner, promocional, por categoría (futuras, configurables; no implementarlas aún).

### 13.4 Fee arrendatario
- MVP: **8 %**, calculado server-side. Preparado para variar por categoría, duración, perfil de riesgo, campañas, tipo de cuenta y demanda. La app nunca calcula el monto definitivo.

### 13.5 Garantía
- **RUÉ determina la garantía server-side**; el propietario no la define libremente.
- Arquitectura: `guarantee_rules` (MVP: reglas simples por categoría) y luego `risk_score` (inputs futuros: vehicle_category, vehicle_value, vehicle_age, rental_duration, use_case, renter_history, owner_history, verification_level, claims_history, risk_flags).
- Nunca un número fijo hardcodeado en la app.
- La garantía **NO es revenue, NO es service fee, NO es precio del arriendo**: separada contable y conceptualmente.

### 13.6 Take rate y métricas financieras
- Registrar: `owner_fee`, `renter_fee`, `other_platform_revenue`, `gross_booking_value`, `net_revenue`, `effective_take_rate`.
- GMV/GBV = valor bruto transaccionado según la definición contable adoptada. Net Revenue = ingreso atribuible a RUÉ (definir qué conceptos son ingreso). Take Rate = ingresos marketplace / GMV, con definición consistente.
- No mezclar garantía con revenue. No contar dinero retenido temporalmente como ingreso.

### 13.7 Payout propietario
- Regla: **T+2 días hábiles** después de que la reserva quede correctamente devuelta.
- Retención (held) por: damage_reported, open_dispute, late_return, unpaid_extra_charge, fraud_review, payment_issue.
- Estados explícitos: **pending, eligible, scheduled, paid, held, failed**. No inferir el payout solo desde el estado de la reserva.
- No simular transferencias que el proveedor no permite. Ledger interno consistente.
- **RUÉ Fast Payout** (futuro, no ahora): cobro anticipado por fixed_fee o percentage_fee; fuente de ingreso adicional.

### 13.8 RUÉ Pro y RUÉ Fleet (futuro)
- Free (casual) vs **Pro** (lower_take_rate, advanced_analytics, multi_asset_tools, priority_support, pricing_tools, fast_payout, calendar_tools, automation). Sin cobro de suscripción ahora, pero sin decisiones que obliguen a rehacer usuarios/permisos.
- **Fleet**: propietarios con decenas o cientos de activos. Ownership: individual, company, fleet. **No asumir one_user = one_vehicle.** Conceptos: organization, organization_members, vehicles, roles (owner, admin, operator, finance, viewer). No implementar todo; la migración debe ser razonable.
- B2C + B2B: person→person, business→person, person→business, business→business. No asumir que ambas partes son individuos.
- Organizaciones: no construir un ERP; no acoplar información legal a `profiles` de forma que impida agregar organizaciones.

### 13.9 Fuentes de ingreso (roadmap, NO construir ahora)
transaction commission · renter service fee · protection margin/commission (donde sea legal) · booking extensions · late fees (si el contrato lo permite) · fast payout · RUÉ Pro · RUÉ Fleet · featured listings · fleet management · telematics · maintenance partnerships · roadside assistance · insurance partnerships · financing partnerships · B2B services · API/data products (legal y ético).
Cada una debe respetar legislación, contratos, privacidad, impuestos, regulación financiera y de seguros. **No inventar servicios regulados.**

### 13.10 Ledger financiero interno
- Cada reserva produce componentes separados: base_price, owner_fee, renter_fee, tax, discount, protection_fee, delivery_fee, extras, late_fee, additional_usage, guarantee, refund, owner_payout, platform_revenue.
- No guardar solo un total. **Trazabilidad auditable** por un comprador potencial.

### 13.11 Pricing engine
- El propietario define o acepta un precio base; **RUÉ calcula el precio final**.
- `pricing_rules`, `pricing_version`, `pricing_snapshot`. Una reserva conserva el snapshot (inputs, outputs, versión, timestamp). Cambiar reglas mañana **no altera reservas históricas**.

### 13.12 Configuración versionada
- Sistema server-side versionado para: fees, minimum/maximum_booking_duration, payout_delay, guarantee rules, category rules, cancellation policies.
- Nunca depender de publicar una versión móvil para cambiar una comisión. Cambios importantes **auditables**.

### 13.13 Analytics y eventos
- Métricas a poder calcular (sin mostrar métricas falsas; guardar eventos para cuando haya datos): GMV, net revenue, effective take rate, completed bookings, booking conversion, search-to-book conversion, match rate, zero-result searches, vehicle utilization, available days, booked days, time to first booking, time to match, repeat renter/owner rate, owner/renter GMV retention, cancellation rate, dispute rate, claim rate, average booking value/duration, supply/demand concentration, organic/paid acquisition, CAC y contribution margin (cuando existan).
- **Domain events** consistentes: user_created, vehicle_created, vehicle_published, vehicle_unpublished, search_performed, vehicle_viewed, booking_requested, booking_accepted, booking_rejected, checkout_started, payment_approved, payment_rejected, booking_confirmed, booking_started, vehicle_returned, booking_completed, booking_cancelled, dispute_opened, dispute_closed, payout_eligible, payout_paid.
- Los eventos financieros críticos se **originan o verifican server-side**.
- Geo: métricas por country, region, city, zone. Expansión progresiva; no abrir geografías sin supply.

### 13.14 Supply
- Retención de supply: que el propietario publique, consiga su primera reserva rápido, tenga buena experiencia, vuelva a disponibilizar y aumente su GMV.
- UX del propietario: available_days, booked_days, revenue, utilization, next_booking; luego estimated_earnings (**siempre marcado como estimación**, nunca engañoso).
- Liquidez: optimizar por active_supply, available_supply, bookable_supply, utilized_supply — no por cantidad de listings. Un vehículo nunca disponible no es supply líquido.

### 13.15 Search, confianza, reseñas y datos
- Ranking futuro: availability, distance, price, quality, rating, response speed, conversion, reliability. **No pay-to-win absoluto**; destacados identificados como tales.
- Trust graph: verification status, completed bookings, cancellations, late returns, claims, disputes, ratings, response metrics, account age. Sin exponer datos sensibles; **un risk score interno nunca es una etiqueta pública discriminatoria**.
- Reseñas solo de una relación/transacción válida (reviewer, reviewee, booking_id, rating, text, created_at + restricciones).
- Data moat: datos estructurados para pricing, risk, availability, matching, utilization, forecasting (qué categorías rotan, qué zonas demandan, tiempo hasta reservarse, qué disponibilidad y precios convierten, incidentes por categoría, propietarios que crecen). **Privacidad y minimización primero.**

### 13.16 Asset-light, exit readiness y norma técnica
- RUÉ es marketplace / operating layer; si algún día hay inventario propio, separado contable y técnicamente.
- Compradores hipotéticos (no construir para uno): marketplaces de movilidad, rent-a-car, automotrices, aseguradoras, fintech, bancos, leasing, fleet management, telematics, delivery/logistics, super apps, plataformas gig. El valor está en network, transactions, technology, data, supply, demand, brand y unit economics — no en inventario.
- Mantener: migraciones limpias, security policies, ledger, historial de eventos, historial de configuración, versiones de pricing, eventos de pago, definiciones de analytics, documentación y tests de lógica crítica.
- Evitar: magic numbers, lógica financiera duplicada, estado crítico decidido por el cliente, datos sensibles dispersos, dependencias innecesarias, código sin ownership claro.
- **Norma técnica principal**: ninguna regla económica vive solo en React Native. Frontend presenta, recoge intención y solicita; backend autoriza, calcula, valida, persiste y cambia estados críticos.
- **Prioridad actual**: 1) app funcionando, 2) backend seguro, 3) flujo completo de una transacción, 4) oferta real, 5) demanda real, 6) primera reserva, 7) repetición, 8) liquidez.

### 13.17 Brechas entre el código actual y esta arquitectura (diagnóstico 2026-10-01)

**Ya alineado:** precio, fees, montos y estados calculados y cambiados solo en el servidor; montos congelados por reserva (trigger); componentes separados en `bookings` (arriendo, fee arrendatario, comisión, total, payout, garantía — garantía fuera del total); `payments` + `payment_events` con idempotencia; `booking_events` (historial de estados); `vehicle_type` multimodal + `attributes` jsonb; reseñas atadas a reserva finalizada; verificaciones; RLS en todo; migraciones + tests; sin flota propia.

**Corregido en 0008 (2026-10-01):**
1. ✅ Fees 15 %/8 % en `economic_config_versions` (versionada, inmutable, auditada); fuera de `platform_settings`.
2. ✅ Garantía por `guarantee_rules` (RUÉ), el propietario ya no la define.
3. ✅ `pricing_snapshot` + `economic_config_id` + `guarantee_rule_id` por reserva.
4. ✅ `ledger_entries` inmutable con bruto/neto/impuesto separados.
5. ✅ Payout al devolver, estados pending/eligible/scheduled/paid/held/failed, T+2 días hábiles.
6. ✅ `domain_events` + `search_performed` (zero-result) + `marketplace_summary`.

**Pendiente de esa lista:** IVA (contador); costo real de Transbank por transacción (se registra a mano con `record_processing_cost`).

**Aplazar (camino abierto):** organizaciones/Fleet/roles, RUÉ Pro, Fast Payout, risk_score, tasas por tier/categoría/campaña, ranking avanzado, featured listings, dashboard de métricas, estimated_earnings, normalización geográfica (region/zone), impuestos en el ledger (requiere contador), migrar el enum `vehicle_type` a tabla de categorías (hoy las reglas por categoría pueden colgar del enum; `ALTER TYPE … ADD VALUE` permite agregar tipos).

## 14. Principio de producto: marketplace transaccional completo — definición del dueño, 2026-10-01

> RUÉ **no** es solo un marketplace de listings. Debe capturar todo el ciclo de vida de una operación, de modo que propietario y arrendatario obtengan **más valor quedándose en RUÉ** que operando directo: *"Reservar por fuera = perder protección, trazabilidad y comodidad."* El objetivo no es solo impedir que se vayan.

**Ciclo**: Discovery → Offer → Negotiation → Booking → Payment → Verification → Digital agreement → Check-in → Active rental → Extension → Check-out → Damage/Dispute → Payout → Review.

**Pregunta central para cada feature**: *¿Hace que RUÉ sea más útil como infraestructura transaccional de movilidad?* Si solo decora, no es prioridad. No optimizar por cantidad de listings: optimizar active listings, liquid supply, successful matches, completed transactions, repeat transactions, GMV, net revenue, utilization, retention.

### 14.1 Negociación (inspirada en inDrive)
- El propietario define el **precio publicado**. RUÉ calcula server-side el **precio recomendado** y el **precio mínimo permitido** (propiedad de RUÉ; no se expone el número, solo "Esta oferta está bajo el mínimo permitido.").
- El mínimo debe poder considerar progresivamente: categoría, valor, duración, ubicación, demanda, disponibilidad, temporada, riesgo y reglas del propietario (`offer_rules.conditions`). Nunca en React Native.
- El arrendatario ofrece ≥ mínimo; el propietario acepta, rechaza o contraoferta. **Máximo 3 rondas.** El backend valida disponibilidad, reglas de precio, mínimo, duración, elegibilidad, riesgo y estado de la oferta. Cada oferta queda registrada (`booking_offers`: id, booking, sender, recipient, amount, currency, status, round_number, expires_at, created_at; estados pending, accepted, rejected, countered, expired, cancelled). Sin ofertas simultáneas que puedan generar doble reserva.

### 14.2 Desintermediación
- No exponer teléfono, correo, dirección personal ni datos de pago externos antes de una reserva confirmada cuando no sea necesario. El chat vive en RUÉ.
- Moderar y detectar intentos de sacar la operación (WhatsApp, +56, transferencia, Mercado Pago directo, "págame afuera", "te hago descuento si…") y **marcar para revisión** según reglas de seguridad y privacidad, **sin bloquear conversaciones normales**.

### 14.3 Valor de quedarse en RUÉ
Identidad verificada, pago procesado, garantía administrada, contrato digital, check-in digital, fotos pre y post, kilometraje y combustible registrados, historial, disputas, soporte, reputación, extensiones, registro de daños, payout al propietario.

### 14.4 Check-in / check-out
Fotos, timestamp, ubicación cuando legalmente corresponda, kilometraje, combustible, daños existentes y aceptación de ambas partes; mismo proceso al devolver; estado comparable antes/después. Sin computer vision obligatoria en MVP, pero con estructura para `damage_detection`, `photo_comparison`, `odometer_ocr`.

### 14.5 Extensiones
Solicitud desde la reserva: verifica disponibilidad, recalcula precio y fee, pide aprobación del propietario cuando corresponda, procesa pago, actualiza la reserva y genera snapshot financiero. **Nunca modificar silenciosamente una reserva histórica.**

### 14.6 Repeat transactions
Si dos usuarios ya completaron una reserva, podrán tener condiciones especiales configurables (menor fee, proceso acelerado, menor fricción). **No implementar descuentos todavía**; guardar historial suficiente (hoy: `pricing_snapshot.relationship`).

### 14.7 Trust layer
Usuario: identidad verificada, arriendos completados, cancelaciones, disputas, reseñas, tiempo de respuesta, antigüedad. Vehículo: verificado, completados, utilización, reseñas, historial de incidentes. Sin exponer información privada.

### 14.8 Protección
Producto **separado** del precio del arriendo. No inventar coberturas. Antes de producción, validar con abogado y aseguradora: qué cubre, quién es asegurado, RC, daño físico, robo, asistencia, uso comercial, uso en plataformas de transporte. La UI puede reservar espacio, pero nunca afirmar una cobertura inexistente.

### 14.9 RUÉ Pro y RUÉ Fleet (preparar, no construir)
- Pro: menor take rate, analytics, pricing, multi-vehículo, calendario, fast payout, soporte prioritario. Camino: tasas por tier como nueva dimensión de `economic_config_versions` (o tabla de tasas por segmento) resuelta en `price_booking`; analytics desde `domain_events`/`vehicle_trust`.
- Fleet: `organizations`, `organization_members` (roles owner/admin/operator/finance/viewer), `vehicles.organization_id` nullable, operadores que hacen check-in por la organización. Hoy nada asume un vehículo por usuario; los datos legales no están en `profiles` (están en `profile_private`), así que una organización puede tener sus propios datos legales. No construir un ERP.

## 15. Runbook de la beta privada (ejecutar cuando existan las variables de `BETA.md`)

Proyecto Supabase del dueño (creado 2026-10-01): `https://wxkekdlmhimdijewtsef.supabase.co` (ref `wxkekdlmhimdijewtsef`). Verificar que `SUPABASE_PROJECT_REF` coincida; si no, preguntar antes de tocar nada.

Variables esperadas: `EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_PROJECT_REF`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `EXPO_TOKEN`, `EXPO_APPLE_TEAM_ID`, `EXPO_ASC_ISSUER_ID`, `EXPO_ASC_KEY_ID`, `EXPO_ASC_API_KEY_P8`. Nunca imprimirlas en logs ni commitearlas.

1. Red: `curl -s -o /dev/null -w '%{http_code}' https://api.supabase.com` (y expo.dev). Si da 000, pedir al dueño el acceso de red (BETA.md paso 5).
2. Supabase: `bash scripts/apply-migrations.sh --dry-run` → si el proyecto no está vacío y no hay registro de migraciones, **detenerse y preguntar** (no reaplicar). Luego sin `--dry-run`.
3. `update platform_settings set value = to_jsonb('<EXPO_PUBLIC_SUPABASE_URL>'::text) where key = 'supabase_url'` (activa push). Verificar `cron.job` (3 jobs: rue-expire-bookings, rue-expire-vehicle-verifications, rue-promote-payouts), extensiones pg_cron/pg_net, buckets (vehicle-photos, documents, handovers), publicación realtime.
4. Funciones: `npx supabase functions deploy webpay-create webpay-return push-dispatch delete-account --project-ref $SUPABASE_PROJECT_REF --use-api` y `npx supabase secrets set TBK_ENVIRONMENT=test --project-ref $SUPABASE_PROJECT_REF`. `verify_jwt` sale de `supabase/config.toml`.
5. Expo: `npx eas-cli init --non-interactive --force` (escribe `extra.eas.projectId`/`owner` en app.json → commitear). Variables públicas a EAS: `npx eas-cli env:create --environment preview --environment production --name EXPO_PUBLIC_SUPABASE_URL --value "$EXPO_PUBLIC_SUPABASE_URL" --visibility plaintext --non-interactive` (ídem ANON_KEY). Los perfiles de `eas.json` leen `environment` preview/production.
6. Android: `npx eas-cli build --platform android --profile preview --non-interactive --no-wait` → link del APK para el dueño.
7. iOS: escribir `EXPO_ASC_API_KEY_P8` a un archivo temporal fuera del repo (convertir `\n` literales a saltos de línea) y exportar `EXPO_ASC_API_KEY_PATH`; `npx eas-cli build --platform ios --profile production --non-interactive`. El dueño crea la app en App Store Connect (Bundle ID `cl.rue.app`; si Apple dice que el Bundle ID está tomado, usar otro y avisar) y entrega el **Apple ID numérico** de la app → `submit.production.ios.ascAppId` en eas.json → `npx eas-cli submit --platform ios --profile production --latest --non-interactive`. Agregar al dueño como tester interno en TestFlight.
8. E2E contra el proyecto real (dos cuentas de prueba creadas por la API de Auth, sin confirmar correo): publicar, buscar, ofertar bajo el mínimo (debe fallar), contraoferta, cuarta ronda (debe fallar), aceptar, `webpay-create` → completar el formulario de integración con Playwright y la tarjeta de prueba → verificar `confirmada` solo tras el commit, pago rechazado, actas con confirmación de ambos, `en_curso`, devolución, comparación, `devuelta` → payout `pending`, `finalizada`, reseña; errores de permisos, fechas ocupadas y saltos de estado. Borrar o marcar los datos de prueba al terminar.
9. Informe final con el formato que pidió el dueño ("RUÉ — ESTADO DE LANZAMIENTO").
