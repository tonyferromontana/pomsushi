# CLAUDE.md — Memoria técnica de RUÉ

> Leer este archivo al inicio de cada sesión. Mantenerlo actualizado al cerrar cada etapa.

## 0. Estado real del repositorio (actualizado 2026-09-29)

**El código de la app (antes "Rueda") NO está en este repositorio.**

- Repo: `tonyferromontana/pomsushi`. Contiene solo el archivo `store` (un componente React web de pedidos de sushi, "Menú de Pomsushi"), sin relación con RUÉ.
- No existen: `README.md`, `package.json`, `app/`, `src/`, `src/theme.ts`, `src/components/ui.tsx`, `supabase/migrations/`, `supabase/functions/`, `.env.example`, `app.json`, `tsconfig.json`.
- Repos accesibles revisados en la sesión: `lucianoirigoyen/demotion`, `lucianoirigoyen/TheCareBot` (de otro dueño, no revisados), `tonyferromontana/pomsushi`. Ninguno se identifica como Rueda/RUÉ.
- Entorno: Node v22.22.2, npm 10.9.7.

Todo lo que sigue (secciones 1–11) es la **especificación del dueño**, no una descripción de código existente. Cuando llegue el código, reemplazar las secciones marcadas `[PENDIENTE AUDITORÍA]` con lo que realmente hay.

**No borrar `store`** sin autorización del dueño.

## 1. Qué es RUÉ

- Marca: **RUÉ** (se pronuncia ru-é). Antes se llamaba **Rueda**. Donde no se pueden usar tildes (bundle IDs, slugs, URLs, variables): `rue`.
- No renombrar paquetes, tablas ni identificadores de "Rueda" hasta comprobar que la app funciona (Etapa 1). Primero estabilidad, después rebranding (Etapa 2).
- RUÉ es un **marketplace de activos de movilidad**, no una app de arriendo de autos. Conecta a quien tiene vehículos parados con quien los necesita temporalmente.
- Promesa: *Haz producir lo que tienes parado.* Alternativa: *Muévelo. Hazlo producir.*
- Activos: autos, motos, camionetas, SUV, vans, furgones, minibuses, camiones, trailers, comerciales, especializados. El modelo usa `vehicle`/`asset`, nunca `car`.
- "Modo Finde" (arriendo corto por días) y "Modo Pega" (semanal para Uber/DiDi/Cabify) quedan como **casos de uso o filtros**, no como la estructura principal.
- Navegación: ¿Qué necesitas? (tipo) → ¿Cuándo? (inicio/término) → ¿Para qué? (opcional: viaje, ciudad, trabajo, aplicaciones, reparto, carga, otro).
- Principio de producto: *¿Esto hace más fácil que un activo parado encuentre a alguien que lo necesita?*

## 2. Stack esperado

Expo SDK 57 · React Native · Expo Router · TypeScript · Supabase (Postgres, Auth, Storage, Realtime, Edge Functions en Deno) · Mercado Pago Checkout Pro.

Antes de agregar dependencias: confirmar que hacen falta, que no duplican otra y que son compatibles con SDK 57. Mapas y analytics: no instalar proveedor sin discutirlo con el dueño.

## 3. Estructura del proyecto `[PENDIENTE AUDITORÍA]`

Esperada: `app/` (rutas Expo Router), `src/theme.ts`, `src/components/ui.tsx`, `supabase/migrations/0001_*.sql`, `0002_*.sql`, `supabase/functions/*`.

## 4. Sistema de diseño

Todo token vive en `src/theme.ts`; primitivas en `src/components/ui.tsx`. Prohibido escribir colores o fuentes sueltos en componentes.

**Paleta RUÉ** (reemplaza la de Rueda en la Etapa 2):

| Token | Hex | Uso |
|---|---|---|
| asphalt | `#101114` | fondo oscuro, navegación, superficies premium |
| carbon | `#181A1F` | cards e inputs oscuros |
| bone | `#F5F3EE` | fondos claros, texto sobre negro |
| graphite | `#868A93` | texto secundario, metadata |
| lime (RUÉ Electric Lime) | `#D7FF3F` | CTA principal, estados activos, acento del logo. Usar como golpe visual, nunca inundar |

Además: tokens semánticos `success`, `warning`, `error`, `info`, `disabled`, `border`, `surface`.

Paleta anterior de Rueda (hasta la Etapa 2): asfalto `#14161B`, amarillo `#F5B82E` (Finde), verde `#0D6B61` (Pega).

**Tipografía:** Bricolage Grotesque (headings, números, precios, marca) + DM Sans (UI, formularios, textos, botones). Escala: display, h1, h2, h3, title, body, bodySmall, label, caption, priceLarge. No agregar otras familias.

**Estilo:** premium, tecnológico, limpio, chileno, humano. Evitar: template genérico, estética de rent-a-car, gradientes excesivos, glassmorphism, sombras exageradas, emojis como diseño, cards sin jerarquía.

**Logo:** monograma "R" que sugiere movimiento/camino/flujo; la "É" con acento en lime. Icono: fondo negro/charcoal + R + lime. No inventar un SVG mediocre: pedir al dueño `logo.svg`, `logo-mark.svg`, `icon.png` (1024×1024), `adaptive-icon.png` (1024×1024, con margen de seguridad), `splash.png`.

**Microcopy:** español de Chile, cercano y claro, ni flaite ni corporativo. "Reservar", no "Proceder con la reservación". "Este vehículo no está disponible para esas fechas."

**Estados de UI:** toda pantalla con datos maneja loading, empty, error (sin mensajes técnicos crudos), retry y offline cuando aplique.

## 5. Modelo de datos `[PENDIENTE AUDITORÍA]`

Objetivo: tabla base de vehículos con `vehicle_type` (propuesta: car, motorcycle, suv, pickup, van, cargo_van, truck, minibus, trailer, special) y atributos variables por tipo (p. ej. JSONB validado por tipo o tablas de atributos), sin una tabla de 80 columnas nullable. Diseñar después de ver el modelo real; migrar de forma incremental, sin reescrituras destructivas.

Confianza y reputación a contemplar: identidad/licencia/vehículo verificados, rating, reseñas, cantidad de arriendos, miembro desde, tasa de respuesta, reportes, disputas. Nunca mostrar datos inventados.

## 6. Máquina de estados de la reserva

Flujo feliz:

```
solicitada → aceptada → confirmada → en_curso → devuelta → finalizada
```

| Desde | Hacia | Quién / cómo |
|---|---|---|
| solicitada | aceptada | dueño (RPC server-side) |
| solicitada | rechazada | dueño |
| solicitada | vencida | cron, si el dueño no responde |
| solicitada / aceptada | cancelada | arrendatario o dueño |
| aceptada | confirmada | **solo** el webhook de Mercado Pago verificado |
| aceptada | vencida | cron, si no se paga a tiempo |
| confirmada | en_curso | entrega (RPC) |
| confirmada | cancelada | según política de cancelación (server) |
| en_curso | devuelta | devolución (RPC) |
| devuelta | finalizada | dueño o cron tras la ventana de reclamos; libera la garantía |
| en_curso / devuelta | disputada | cualquiera de las partes |

Estados extra (rechazada, cancelada, vencida, disputada) se agregan solo si el modelo real los necesita. Toda transición se valida en Postgres (función + trigger que rechaza saltos inválidos como `solicitada → finalizada`). El cliente nunca hace `update` directo del estado.

## 7. Reglas inviolables

1. **Dinero y estados en servidor.** Precio final, comisión, descuentos, cargos, garantía y su devolución, monto a pagar, monto al propietario y estados críticos se calculan en SQL/RPC/triggers/Edge Functions. La app solo muestra.
2. **Comisiones configurables server-side** (tabla de configuración). Nunca inventar porcentajes; los define el dueño.
3. **RLS en toda tabla.** RUT, teléfono, dirección privada, licencia, cédula, documentos, datos bancarios, documentos de vehículo/seguro e información financiera nunca son públicos. Storage con policies. La seguridad la define Postgres, no el frontend.
4. **Migraciones:** siempre un archivo nuevo en `supabase/migrations/` (`0003_...`, `0004_...`). Nunca editar las anteriores. Idempotentes cuando sea razonable y comentadas.
5. **Pagos (Mercado Pago Checkout Pro):** la preferencia se crea en el backend con `external_reference` = id de la reserva. La confirmación viene solo del webhook verificado (firma + consulta a la API de MP). Idempotencia: sin doble cobro ni doble confirmación. Registrar eventos de pago. Separar test y prod. Nunca guardar datos de tarjeta.
6. **Secretos:** en el cliente solo `EXPO_PUBLIC_*`. `SUPABASE_SERVICE_ROLE_KEY`, el token de MP y los secretos de webhook van solo como secrets de Edge Functions. Nunca hardcodear.
7. **Chat:** acceso solo para participantes de la reserva y timestamps del servidor.
8. **Garantías y cron** corren en el servidor; nunca dependen de que alguien abra la app.
9. **Observabilidad:** nada de `catch {}` silencioso. Logs útiles en el backend, sin secretos.
10. **Validar:** después de cada cambio de código, `npx tsc --noEmit` sin errores antes de decir "listo".
11. **Sin big-bang:** cambios incrementales. No romper lo que funciona. No borrar sin autorización.

## 8. Modelo de ingresos (preparar, no construir)

Comisión al propietario, fee al arrendatario, protección/cobertura, garantías, extensiones, suscripción para propietarios profesionales, planes de flota, publicaciones destacadas, gestión de flota, GPS/telemetría, mantención, asistencia en ruta, seguros, financiamiento, B2B. Todo configurable en servidor.

## 9. Integraciones externas y variables de entorno `[PENDIENTE AUDITORÍA]`

Cliente (`.env`): `EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_ANON_KEY` (nombres por confirmar con el código real).
Servidor (secrets de Supabase): `SUPABASE_SERVICE_ROLE_KEY`, `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET` (por confirmar).

Analytics (eventos conceptuales, sin proveedor todavía): signup_started, signup_completed, search, vehicle_view, booking_started, booking_requested, booking_accepted, checkout_started, payment_completed, listing_started, listing_completed.

Notificaciones: solicitud nueva, aceptada, rechazada, pago confirmado, reserva próxima, inicio, término, devolución, mensaje nuevo, cambio de reserva, problema con el pago, documento rechazado. Evitar spam.

## 10. Comandos

```bash
node -v && npm -v
npm install
npx tsc --noEmit        # obligatorio después de cada cambio
npx expo start          # abrir con Expo Go (escanear el QR)
npx expo start --tunnel # si el celular no está en la misma red
npx expo-doctor
```

## 11. Etapas (detenerse al final de cada una y esperar el visto bueno del dueño)

0. Auditoría + CLAUDE.md — **bloqueada: falta el código**
1. RUÉ corriendo en el celular con Expo Go (Node, install, tsc, Supabase, migraciones 0001/0002, `.env`)
2. Rebranding RUÉ (tokens, tipografía, logo, splash, icon, textos, eliminar "Rueda")
3. Arquitectura marketplace multimodal (`vehicle_type`, migración nueva)
4. Mercado Pago en modo test (Edge Functions, secrets, webhook, idempotencia)
5. Reserva completa de punta a punta con dos cuentas
6. Garantías, cron y notificaciones
7. Calidad (estados, accesibilidad, performance, seguridad)
8. EAS / TestFlight

Pregunta al dueño solo por decisiones de negocio, dinero, marca, legal, servicios pagados, credenciales, producción o borrados. Las decisiones técnicas reversibles las toma Claude.

## 12. Deuda técnica y hallazgos

| Nivel | Hallazgo |
|---|---|
| Crítico | El código de la app no está en el repositorio: no se puede auditar, correr ni probar nada. |
