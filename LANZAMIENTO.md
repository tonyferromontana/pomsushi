# Lanzar RUÉ: lista de tareas del dueño

Todo el código está hecho y probado. Esta lista es lo que **solo tú** puedes hacer: crear empresas y cuentas, pagar suscripciones, firmar, y tomar decisiones de negocio y legales.
Marca cada punto a medida que avances. Donde dice **"avísale a Claude"**, yo sigo desde ahí.

Los precios son aproximados; confírmalos en cada sitio antes de pagar.

---

## Fase 1 · Empresa y decisiones (semanas 1–3)

- [ ] **Crear la empresa.** Una SpA en https://www.registrodeempresasysociedades.cl (gratis, en el día) y el inicio de actividades en el SII. Anota la razón social, el RUT y el domicilio.
- [ ] **Abrir una cuenta bancaria de la empresa.** Los pagos de los arrendatarios llegan ahí (a través de Mercado Pago) y desde ahí les pagas a los propietarios.
- [ ] **Pedir el número D-U-N-S de la empresa** (gratis): https://developer.apple.com/enroll/duns-lookup/ . Apple y Google lo exigen para publicar como empresa y tarda de 5 a 30 días. **Pídelo hoy.**
- [ ] **Definir los números del negocio** y avisarle a Claude:
  - Comisión al propietario (%).
  - Cargo de servicio al arrendatario (%).
  - Cada cuántos días hábiles les pagas a los propietarios.
  - Política de cancelación: qué se devuelve y cuándo, si cancela el arrendatario o si cancela el propietario.
  - Garantía: si se cobra por la app o se coordina en persona.
  - Edad mínima y antigüedad de licencia para arrendar.
- [ ] **Seguros.** Conversa con una corredora de seguros sobre un seguro para arriendo entre particulares. Es **el riesgo más grande del negocio**: un choque sin cobertura puede quebrar a un propietario o a RUÉ. No lances al público sin tener esto claro.
- [ ] **Abogado.** Llévale `legal/terminos.md` y `legal/privacidad.md` (borradores escritos por Claude). Pídele que:
  - Complete todo lo que está `[ENTRE CORCHETES]`.
  - Valide el rol de RUÉ como intermediario.
  - Revise la responsabilidad por daños y multas.
  - Revise la parte tributaria: IVA de la comisión y quién emite boleta o factura.
  - Te dé un modelo de contrato o acta de entrega entre las partes.
  - Cuando esté listo, mándale los textos finales a Claude.
- [ ] **Marca y dominio.**
  - Revisa si `rue.cl` está disponible en https://www.nic.cl (aprox. $10.000 al año).
  - Evalúa registrar la marca "RUÉ" en https://www.inapi.cl (clases 39, 9 y 42).
- [ ] **Correos:** uno de soporte y uno de privacidad (por ejemplo `soporte@rue.cl` y `privacidad@rue.cl`). Avísale a Claude para ponerlos en la app y en el sitio.
- [ ] **Logo definitivo.** Un diseñador te entrega `logo.svg`, `logo-mark.svg`, `icon.png` (1024×1024), `adaptive-icon.png` (1024×1024, con el logo dentro del 66 % central y fondo transparente) y `splash.png`. Mándalos a Claude.

## Fase 2 · Cuentas técnicas (semana 2)

- [ ] **Supabase** (base de datos), en https://supabase.com:
  1. **New project** → nombre `rue` → región **South America (São Paulo)** → genera y guarda la contraseña.
  2. **SQL Editor → New query:** pega y corre, en orden, `0001`, `0002`, `0003` y `0004` de `supabase/migrations/`. Cada una debe decir "Success".
  3. **Authentication → Sign In / Providers → Email:** para probar, apaga "Confirm email". Antes de lanzar, vuelve a prenderlo.
  4. Antes de lanzar, sube al **plan Pro** (aprox. USD 25 al mes). En el plan gratis el proyecto se pausa si no se usa y el correo de registro tiene un límite muy bajo.
  5. Antes de lanzar, configura un correo propio en **Authentication → Emails → SMTP Settings** (con Resend o Brevo, que tienen plan gratis) y traduce los correos al español.
  6. Copia el **Project URL** y la **anon key** y ponlos en tu archivo `.env`. Si prefieres, **avísale a Claude** y te guía.
- [ ] **Mercado Pago**, con la cuenta de la empresa:
  1. https://www.mercadopago.cl/developers → **Tus integraciones → Crear aplicación** → nombre "RUÉ", producto **Checkout Pro**.
  2. **Credenciales de prueba:** copia el **Access Token de prueba**.
  3. **Webhooks → Configurar notificaciones:** en la URL de producción y la de prueba pon `https://<tu-proyecto>.supabase.co/functions/v1/mp-webhook`, marca el evento **Pagos**, guarda y copia la **clave secreta**.
  4. **Cuentas de prueba:** crea una vendedora y una compradora, para probar pagos con tarjetas de prueba.
  5. Más adelante, para cobrar de verdad: activa las **credenciales de producción** (Mercado Pago te pide datos de la empresa).
- [ ] **Expo** (para compilar la app): crea una cuenta gratis en https://expo.dev con el correo de la empresa.
- [ ] **Apple Developer Program** (aprox. USD 99 al año), en https://developer.apple.com/programs/enroll/: inscríbete **como organización** (necesitas el D-U-N-S).
- [ ] **Google Play Console** (aprox. USD 25, un solo pago), en https://play.google.com/console: cuenta de **organización**. Las cuentas personales nuevas deben hacer 14 días de prueba cerrada con 12 personas antes de publicar.

## Fase 3 · Subir todo (la hago yo si me das acceso)

Hay dos caminos:

**Camino A (recomendado): me das acceso y yo lo hago.** En la configuración del entorno de Claude Code (menú del entorno en la barra de título de la sesión → **Edit**):

1. En **Network access**, permite estos dominios:
   - `supabase.com`, `api.supabase.com`, `*.supabase.co`
   - `expo.dev`, `api.expo.dev`, `exp.host`
   - `api.mercadopago.com`
2. En las **variables de entorno**, agrega (nunca las pegues en el chat):
   - `SUPABASE_ACCESS_TOKEN`: se crea en supabase.com → tu avatar → **Access Tokens**.
   - `SUPABASE_PROJECT_REF`: el código de tu proyecto, lo que va antes de `.supabase.co`.
   - `EXPO_TOKEN`: se crea en expo.dev → **Account settings → Access tokens**.
   - `MP_ACCESS_TOKEN` y `MP_WEBHOOK_SECRET`: los que copiaste de Mercado Pago.
3. Abre una sesión nueva y avísale a Claude. Yo aplico las migraciones, subo las 5 funciones del servidor, configuro las claves, activo las notificaciones, genero la versión de prueba para iPhone (TestFlight) y Android, y la mando a las tiendas.

**Camino B: lo haces tú en tu computador.** Claude te da los comandos exactos uno por uno (Supabase CLI y EAS).

## Fase 4 · Probar de verdad (semanas 3–4)

- [ ] Abre la app con Expo Go o TestFlight y crea **dos cuentas**: una dueña y una arrendataria.
- [ ] Recorre el flujo completo: publicar, solicitar, aceptar, **pagar con tarjeta de prueba**, entregar, devolver, finalizar y dejar reseñas.
- [ ] Prueba también lo que puede salir mal: un pago rechazado, cancelar, una solicitud que vence, reportar y bloquear, y eliminar una cuenta.
- [ ] Hazte administrador y aprueba una licencia siguiendo `OPERACION.md`.
- [ ] Beta privada con 10–20 personas de confianza por TestFlight (iPhone) y prueba interna (Android). Anota todo lo que les confunda.

## Fase 5 · Publicar en las tiendas (semanas 4–6)

- [ ] **Sitio web con los textos legales.** Cuando la rama esté en `main`, entra a GitHub → repositorio → **Settings → Pages → Deploy from a branch → `main` / `docs`**. Te queda una dirección tipo `https://tonyferromontana.github.io/pomsushi/` con Términos, Privacidad, Soporte y "Eliminar cuenta". Las tiendas exigen estas URLs.
  - Ojo: el repositorio es **público**, así que cualquiera puede ver el código. No hay claves ahí, pero si quieres hacerlo privado avísale a Claude para mover el sitio a otro lugar.
- [ ] **App Store Connect:**
  - Crea la app con el bundle `cl.rue.app`.
  - Sube capturas de pantalla, la descripción y las palabras clave (Claude te las redacta).
  - Pon la URL de privacidad y la de soporte.
  - Completa la ficha de privacidad ("App Privacy"): correo, nombre, teléfono, fotos, documentos, pagos procesados por un tercero.
  - Deja una **cuenta de prueba** con un vehículo publicado para el revisor de Apple.
- [ ] **Google Play:**
  - Ficha de la tienda y formulario de **Seguridad de los datos**.
  - URL de eliminación de cuenta: `…/eliminar-cuenta.html`.
  - Clasificación de contenido y público objetivo: mayores de 18.
- [ ] **Cambia a producción:**
  - Credenciales de producción de Mercado Pago (Claude cambia `MP_ENVIRONMENT=prod`).
  - Vuelve a prender "Confirm email".
  - Activa `require_verified_license` (ver `OPERACION.md`).

## Fase 6 · Lanzamiento

- [ ] **Primero la oferta:** consigue 20–30 vehículos publicados (amigos, conocidos, flotas pequeñas, conductores de apps) antes de abrirle la app al público. Un marketplace vacío no retiene a nadie.
- [ ] Define quién revisa todos los días las verificaciones, los reportes y los pagos a propietarios (`OPERACION.md`).
- [ ] Lanza en una sola ciudad (por ejemplo, Santiago oriente) y crece desde ahí.

---

**Resumen de costos fijos aproximados:**

| Servicio | Costo |
|---|---|
| Apple | USD 99 al año |
| Google | USD 25, una vez |
| Supabase Pro | USD 25 al mes |
| Dominio | aprox. $10.000 al año |
| Expo | gratis para empezar |

Mercado Pago cobra una comisión por cada pago; revisa la tarifa vigente en tu cuenta. A eso se suman el abogado, el seguro y el diseño del logo.
