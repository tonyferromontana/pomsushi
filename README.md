# RUÉ

Marketplace de activos de movilidad para Chile: autos, motos, camionetas, vans, furgones, camiones y más.
*Haz producir lo que tienes parado.*

- App: Expo SDK 57 · React Native · Expo Router · TypeScript
- Backend: Supabase (Postgres + RLS, Auth, Storage, Realtime)
- Pagos (próxima etapa): Mercado Pago Checkout Pro vía Edge Functions

La memoria técnica completa (arquitectura, reglas, estados de reserva y backlog) está en [`CLAUDE.md`](./CLAUDE.md).

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
npm run test:db
```

## Validaciones

```bash
npx tsc --noEmit
npx expo lint
```
