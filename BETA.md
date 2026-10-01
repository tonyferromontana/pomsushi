# RUÉ — Beta privada: lo que falta para tenerla en tu teléfono

El código está listo: compila para iPhone y Android y pasa todas las pruebas. Lo que falta son **cuentas tuyas** y **darle acceso a Claude** para que suba todo y compile la app. Claude no puede crear cuentas a tu nombre ni pagar por ti.

Tiempo estimado: 1 hora tuya (más la espera de Apple, de 1 a 2 días).

> Regla de oro: **nunca pegues contraseñas, tokens ni claves en el chat.** Van en la configuración del entorno (paso 5).

---

## Paso 1 · Supabase (base de datos) — gratis

1. Entra a https://supabase.com → **Start your project** → entra con tu cuenta de GitHub.
2. **New project**:
   - Name: `rue`
   - Database Password: aprieta **Generate a password**, cópiala y guárdala (por ejemplo, en las notas protegidas de tu teléfono). Esta es tu **`SUPABASE_DB_PASSWORD`**.
   - Region: **South America (São Paulo)**
   - Aprieta **Create new project** y espera unos 2 minutos.
3. En el menú izquierdo: ⚙️ **Project Settings → General**. Copia el **Project ID** (letras raras, por ejemplo `abcdxyzqwerty`). Ese es tu **`SUPABASE_PROJECT_REF`**.
4. ⚙️ **Project Settings → API Keys**:
   - Copia la **URL del proyecto** (`https://<tu Project ID>.supabase.co`). Esa es tu **`EXPO_PUBLIC_SUPABASE_URL`**.
   - Copia la **Publishable key** (empieza con `sb_publishable_`) o, en la pestaña *Legacy*, la **anon public** (empieza con `eyJ`). Esa es tu **`EXPO_PUBLIC_SUPABASE_ANON_KEY`**. *(Es pública: no es secreta. NO copies la `service_role` ni la `secret`.)*
5. **Authentication → Sign In / Providers → Email** → apaga **Confirm email** → **Save**. (Así puedes crear cuentas de prueba sin confirmar el correo. Antes del lanzamiento público lo volvemos a prender.)
6. Arriba a la derecha, tu avatar → **Account preferences → Access Tokens** → **Generate new token** → nombre `claude-rue` → cópialo. Ese es tu **`SUPABASE_ACCESS_TOKEN`**.

## Paso 2 · Expo (compila la app) — gratis

1. Entra a https://expo.dev → **Sign up** (mejor con el correo que usarás para RUÉ).
2. Arriba a la derecha, tu avatar → **Account settings → Access tokens** → **Create token** → nombre `claude-rue` → cópialo. Ese es tu **`EXPO_TOKEN`**.

## Paso 3 · Apple Developer (para iPhone) — USD 99 al año

Sin esto no se puede instalar en iPhone por TestFlight. Android no lo necesita.

1. Entra a https://developer.apple.com/programs/enroll/ → **Start your enrollment** → entra con tu Apple ID (debe tener verificación en dos pasos).
2. Elige el tipo de cuenta:
   - **Individual (persona)**: lo más rápido (1 a 2 días). En TestFlight aparecerá tu nombre como desarrollador. Más adelante la app se puede transferir a la cuenta de la empresa.
   - **Organization (empresa)**: necesitas la empresa creada y el número D-U-N-S (puede tardar semanas).

   **Para la beta recomiendo Individual.**
3. Paga los USD 99 y espera el correo de Apple diciendo que tu membresía está activa.
4. En https://developer.apple.com/account → **Membership details**, copia el **Team ID** (10 caracteres). Ese es tu **`EXPO_APPLE_TEAM_ID`**.
5. Crea la llave para que Claude compile y suba la app sin tu contraseña de Apple:
   - Entra a https://appstoreconnect.apple.com → **Users and Access → Integrations → App Store Connect API**.
   - Si te lo pide, aprieta **Request Access** y acepta. Después, en **Team Keys**, aprieta **+**.
   - Nombre: `EAS` · Access: **Admin** → **Generate**.
   - Copia el **Issuer ID** (arriba de la lista). Ese es tu **`EXPO_ASC_ISSUER_ID`**.
   - Copia el **Key ID** de la llave nueva. Ese es tu **`EXPO_ASC_KEY_ID`**.
   - Aprieta **Download API Key**. Se baja un archivo `AuthKey_XXXX.p8` (**solo se puede bajar una vez**; guárdalo). Ábrelo con el Bloc de notas o TextEdit y copia **todo** el texto, incluidas las líneas `-----BEGIN PRIVATE KEY-----` y `-----END PRIVATE KEY-----`. Ese es tu **`EXPO_ASC_API_KEY_P8`**.

## Paso 4 · Android — nada que hacer

Para la beta, Android se instala con un archivo APK directo (sin Google Play). No necesitas cuenta de Google Play todavía.

## Paso 5 · Darle acceso a Claude

En Claude Code, en la barra de título de la sesión, abre el menú del **entorno en la nube** → **Edit**:

1. **Network access**: para esta puesta en marcha, elige el acceso **completo** (Full). Si prefieres solo una lista, permite:
   - `supabase.com`, `api.supabase.com`, `*.supabase.co`
   - `expo.dev`, `*.expo.dev`, `exp.host`, `storage.googleapis.com`
   - `appstoreconnect.apple.com`, `api.appstoreconnect.apple.com`, `developer.apple.com`, `*.apple.com`
   - `webpay3gint.transbank.cl`, `*.transbank.cl`
2. **Environment variables**: agrega una por línea (nombre = valor):

   | Variable | De dónde |
   |---|---|
   | `EXPO_PUBLIC_SUPABASE_URL` | Paso 1.4 |
   | `EXPO_PUBLIC_SUPABASE_ANON_KEY` | Paso 1.4 |
   | `SUPABASE_PROJECT_REF` | Paso 1.3 |
   | `SUPABASE_ACCESS_TOKEN` | Paso 1.6 |
   | `SUPABASE_DB_PASSWORD` | Paso 1.2 |
   | `EXPO_TOKEN` | Paso 2.2 |
   | `EXPO_APPLE_TEAM_ID` | Paso 3.4 |
   | `EXPO_ASC_ISSUER_ID` | Paso 3.5 |
   | `EXPO_ASC_KEY_ID` | Paso 3.5 |
   | `EXPO_ASC_API_KEY_P8` | Paso 3.5 (todo el texto del archivo .p8) |

   Si el campo no acepta el texto del `.p8` en varias líneas, pégalo en una sola línea reemplazando cada salto de línea por `\n`.
3. Guarda y **abre una sesión nueva** (las variables solo las ve una sesión nueva). Escribe: **"Sigue con BETA.md"**.

No necesitas código de comercio de Transbank: la beta usa el **ambiente de pruebas público** de Webpay, con tarjetas de prueba (no se cobra dinero real).

---

## Lo que hace Claude después (sin pedirte nada más)

1. Verifica que el proyecto de Supabase esté vacío y aplica las 9 migraciones en orden, una sola vez.
2. Sube las 4 funciones del servidor (`webpay-create`, `webpay-return`, `push-dispatch`, `delete-account`) y configura Webpay en modo pruebas.
3. Activa las notificaciones y revisa Auth, Storage, Realtime, cron y la seguridad (RLS).
4. Crea el proyecto en Expo y guarda ahí las variables públicas de la app.
5. Compila **Android (APK)** y **iPhone (para TestFlight)**.
6. Prueba de punta a punta con dos cuentas: publicar, buscar, ofertar, contraofertar, aceptar, pagar con tarjeta de prueba, entrega, devolución, finalizar, payout pendiente y reseña. También prueba los errores: oferta bajo el mínimo, cuarta ronda, pago rechazado, fechas ocupadas, permisos y saltos de estado.

**Un solo paso extra en iPhone:** después de la primera compilación, Claude te pedirá crear la ficha de la app en App Store Connect (**Apps → + → New App**, Bundle ID `cl.rue.app`). Son 2 minutos; Apple no deja hacerlo automáticamente.

## Cómo instalar cuando esté lista

- **Android:** Claude te da un link de Expo. Ábrelo en el teléfono → **Install** → descarga el APK → si Android pregunta, permite **instalar apps desconocidas** para tu navegador → **Instalar**.
- **iPhone:** instala **TestFlight** desde la App Store. Te llegará un correo de invitación de Apple → **View in TestFlight** → **Install**.

## Tarjetas de prueba de Webpay (no cobran dinero real)

- **Aprobada:** VISA `4051 8856 0044 6623`, CVV `123`, cualquier fecha futura.
- **Rechazada:** Mastercard `5186 0595 5959 0568`, CVV `123`.
- En la pantalla del "banco" de prueba: RUT `11.111.111-1`, clave `123`.

## Qué NO hay en la beta (a propósito)

- **Seguro o protección:** RUÉ no ofrece ninguno, y la app lo dice.
- **Garantía:** se muestra como referencial y **no se cobra** hasta que Transbank confirme cómo bloquear el cupo.
- **Textos legales:** son borradores y les faltan los datos de la empresa (razón social, RUT, domicilio, correos y plazos). Sirven para una beta privada con gente de confianza, **no** para publicar en las tiendas.
- **Pagos a propietarios:** se transfieren a mano (`OPERACION.md`, punto 5).
