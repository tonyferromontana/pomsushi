# RUÉ

Marketplace de activos de movilidad para Chile: autos, motos, camionetas, vans, furgones, camiones y más.
*Haz producir lo que tienes parado.*

- App: Expo SDK 57 · React Native · Expo Router · TypeScript
- Backend: Supabase (Postgres + RLS, Auth, Storage, Realtime)
- Pagos: Mercado Pago Checkout Pro vía Edge Functions (`supabase/functions/`)

- Memoria técnica (arquitectura, reglas, estados de reserva, backlog): [`CLAUDE.md`](./CLAUDE.md)
- Lista de tareas para lanzar: [`LANZAMIENTO.md`](./LANZAMIENTO.md)
- Manual del administrador: [`OPERACION.md`](./OPERACION.md)
- Textos legales (fuente): [`legal/`](./legal) · sitio web generado: [`docs/`](./docs)

## Correr la app

```bash
npm install
cp .env.example .env        # y completa los datos de Supabase
npx expo start              # escanea el QR con Expo Go
```

Si el celular no está en la misma red Wi-Fi que el computador: `npx expo start --tunnel`.

## Base de datos

Las migraciones están en `supabase/migrations/` y se aplican en orden (`0001`, `0002`, …).
Para aplicarlas a mano: Supabase → SQL Editor → pegar el contenido de cada archivo → Run.

Pruebas locales de las migraciones (requiere Postgres instalado):

```bash
npm run test:db          # migraciones + pruebas de seguridad y reservas
npm run test:functions   # Edge Functions (requiere Deno)
npm run legal            # regenera textos legales de la app y del sitio
```

## Validaciones

```bash
npx tsc --noEmit
npx expo lint
```
