# CLAUDE.md — Memoria técnica de RUÉ

> Leer este archivo al inicio de cada sesión. Actualizarlo al cerrar cada etapa.
> El dueño del negocio (Antonio) no es programador: explicar en español simple, pasos exactos cuando algo dependa de él.

## 0. Estado actual (2026-09-29)

- El repo `tonyferromontana/pomsushi` no tenía código de Rueda. RUÉ se construyó **desde cero** en esta sesión (el dueño lo pidió explícitamente).
- El archivo `store` (componente web de pedidos de sushi, ajeno a RUÉ) se conserva sin tocar. No borrarlo sin autorización.
- **Etapa actual: 1 — RUÉ corriendo en el celular.** Código listo y validado; falta que el dueño cree el proyecto Supabase, corra las migraciones y llene `.env`.
- Como no existía "Rueda", se usa la marca y la paleta **RUÉ desde el inicio** (no hay rebranding pendiente de nombres internos). Bundle ID provisorio: `cl.rue.app`.

## 1. Qué es RUÉ

- **RUÉ** (ru-é). Sin tildes: `rue`. Antes "Rueda".
- **Marketplace de activos de movilidad**, no una app de arriendo de autos. Conecta a quien tiene vehículos parados con quien los necesita temporalmente (personas, pymes, conductores de apps, empresas).
- Promesa: *Haz producir lo que tienes parado.* Alternativa: *Muévelo. Hazlo producir.*
- "Modo Finde" y "Modo Pega" NO son estructura: existen como **propósitos** (`viaje`, `aplicaciones`, …) y como precio semanal opcional.
- Principio de producto: *¿Esto hace más fácil que un activo parado encuentre a alguien que lo necesita?*

## 2. Stack

Expo SDK 57 (expo 57.0.26, React Native 0.86, React 19.2) · Expo Router 57 (rutas en `src/app/`) · TypeScript strict · Supabase (Postgres + RLS, Auth email/contraseña, Storage, Realtime) · Mercado Pago Checkout Pro (Etapa 4, aún no implementado).

Dependencias agregadas (todas funcionan en Expo Go): `@supabase/supabase-js`, `@react-native-async-storage/async-storage` (sesión), `@expo-google-fonts/bricolage-grotesque`, `@expo-google-fonts/dm-sans`, `@react-native-community/datetimepicker`, `expo-image-picker`, `expo-image-manipulator` (compresión de fotos), `@expo/vector-icons`. Sin mapas ni analytics todavía (decisión pendiente con el dueño).

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
    publish.tsx              # Asistente de publicación en 5 pasos (crear / editar)
  components/
    ui.tsx                   # Primitivas: Text, Wordmark, Screen, Button, IconButton, Input, FieldButton,
                             # Chip, Segmented, Card, Divider, SectionHeader, Row, Badge, Price, Avatar,
                             # Skeleton, LoadingState, EmptyState, ErrorState, Notice
    VehicleCard.tsx          # Tarjeta de vehículo + VehiclePhoto (placeholder por tipo)
    DateRangeField.tsx       # Selector de fechas (Android: diálogo nativo; iOS: hoja con calendario)
    SetupNeeded.tsx          # Pantalla si falta .env
  lib/
    supabase.ts              # Cliente (solo EXPO_PUBLIC_*), photoUrl()
    auth.tsx                 # AuthProvider / useAuth
    types.ts                 # Tipos del dominio (reflejan las migraciones)
    catalog.ts               # Tipos de vehículo, propósitos, estados, atributos por tipo
    format.ts                # $ chileno, fechas (solo presentación)
    errors.ts                # friendlyError() / logError()
    useAsync.ts              # Carga con loading / error / reintento
    analytics.ts             # track() — eventos definidos, sin proveedor
  theme.ts                   # Tokens de diseño (única fuente)
supabase/
  migrations/0001_core_schema.sql
  migrations/0002_booking_engine.sql
  tests/run.sh               # Levanta Postgres temporal, aplica migraciones y corre pruebas
  tests/supabase_stub.sql    # Imitación mínima de auth/storage/roles de Supabase (solo pruebas)
  tests/booking_flow.test.sql
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
| `payment_events` | webhooks crudos, idempotencia | solo servidor |
| `platform_settings` | comisiones y plazos configurables | solo servidor |

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
| aceptada | confirmada | **solo** `confirm_booking_payment` (webhook MP, service_role) |
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

## 7. Reglas inviolables

1. Dinero y estados en el servidor. La app solo muestra lo que devuelven las RPC.
2. Comisiones configurables en `platform_settings`. Nunca inventar porcentajes.
3. RLS en toda tabla nueva. Datos sensibles (RUT, teléfono, dirección, licencia, cédula, documentos, banco, info financiera) nunca públicos. Storage con policies.
4. Migraciones: siempre un archivo **nuevo** (`0003_…`). No editar 0001/0002 una vez aplicadas en Supabase. Correr `npm run test:db` y agregar pruebas al cambiar el esquema.
5. Pagos: preferencia creada en backend, confirmación solo por webhook verificado + consulta a la API de MP, idempotencia, test/prod separados, nunca datos de tarjeta.
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

Servidor (Etapa 4, secrets de Edge Functions): `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET`, `MP_ENVIRONMENT` (`test`/`prod`). `SUPABASE_SERVICE_ROLE_KEY` la inyecta Supabase en las funciones.

Configuración de Supabase para pruebas: Authentication → Sign In / Providers → Email → desactivar "Confirm email" facilita probar con cuentas falsas (reactivar antes de producción).

## 10. Estado por módulo

| Módulo | Estado |
|---|---|
| Base de datos (0001, 0002) + RLS + Storage | ✅ hecho, probado localmente (`npm run test:db`); ⏳ falta aplicarlo en Supabase real |
| Auth email/contraseña | ✅ |
| Explorar (filtros, paginación de 20) | ✅ |
| Ficha + cotización servidor + solicitud | ✅ |
| Publicar / editar / pausar (5 pasos, fotos comprimidas) | ✅ |
| Reservas + acciones por rol + historial + realtime | ✅ |
| Chat realtime | ✅ (sin "leído") |
| Perfil + RUT/teléfono privados | ✅ |
| Pago Mercado Pago | ⏳ Etapa 4 (botón "Pagar" visible y deshabilitado) |
| Edge Functions (`supabase/functions/`) | ⏳ Etapa 4 (no existen aún) |
| Cron vencimientos / garantías / notificaciones push | ⏳ Etapa 6 |
| Verificación de identidad, licencia y vehículo | ⏳ backlog (columnas listas, flujo no) |
| Reseñas y reputación | ⏳ backlog (no hay tabla; no se muestran datos falsos) |
| Bloqueo de fechas por el propietario (UI) | ⏳ backlog (tabla `vehicle_blocks` lista) |
| Mapa | ⏳ decisión pendiente del dueño |
| Logo definitivo | ⏳ esperando archivos del dueño |
| EAS / TestFlight | ⏳ Etapa 8 |

## 11. Deuda técnica conocida

| Nivel | Hallazgo |
|---|---|
| Importante | Comisión y cargo de servicio están en 0 %: el dueño debe definirlos antes de cobrar. |
| Importante | Política de cancelación con reembolso no definida: `confirmada → cancelada` no se ofrece en la app. |
| Importante | Garantía: se muestra y se guarda, pero no se cobra ni retiene (definir en Etapa 4/6). |
| Importante | Si un vehículo se pausa, el arrendatario deja de ver su título en reservas antiguas (RLS de `vehicles`); se muestra "Vehículo". Resolver con una vista/RPC de reservas. |
| Mejora | Al guardar fotos se borran y reinsertan las filas de `vehicle_photos`; si falla a mitad, hay que volver a guardar. Pasar a una RPC transaccional. |
| Mejora | `messages.read_at` existe pero no se actualiza (sin "leído"). |
| Mejora | Íconos y splash provisorios. |
| Mejora | Tipos de base de datos escritos a mano (`src/lib/types.ts`); generar con `supabase gen types` cuando esté la CLI (Etapa 4). |

## 12. Etapas (detenerse al final de cada una y esperar visto bueno)

0. Auditoría + CLAUDE.md — ✅
1. RUÉ corriendo en el celular con Expo Go — **en curso** (falta Supabase + `.env` del dueño)
2. Rebranding — mayormente innecesario (se partió como RUÉ); queda logo/íconos definitivos
3. Arquitectura multimodal — base hecha en 0001 (`vehicle_type` + `attributes`); revisar con uso real
4. Mercado Pago test (CLI Supabase, Edge Functions, secrets, webhook, idempotencia)
5. Reserva completa con dos cuentas
6. Garantías, cron y notificaciones
7. Calidad (accesibilidad, performance, seguridad, casos borde)
8. EAS / TestFlight

Preguntar al dueño solo por negocio, dinero, marca, legal, servicios pagados, credenciales, producción o borrados. Lo técnico y reversible lo decide Claude.
