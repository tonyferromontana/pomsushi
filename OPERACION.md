# Operación diaria de RUÉ

Manual para administrar RUÉ desde el panel de Supabase, sin programar.
Todo se hace en **Supabase → SQL Editor → New query**: pegas el bloque, cambias lo que está `<ENTRE ÁNGULOS>` y aprietas **Run**.

> Regla de oro: nunca edites a mano las tablas `bookings` ni `payments` desde el Table Editor. Usa solo los bloques de este manual.

---

## 1. Hacerte administrador (una sola vez)

1. Crea tu cuenta en la app con tu correo.
2. Corre:

```sql
insert into public.admins (user_id)
select id from auth.users where email = '<tu-correo@dominio.cl>';
```

## 2. Comisiones, garantías y plazos

### Comisiones (versionadas)

Las comisiones no se editan: se **publica una versión nueva**. Las anteriores quedan como historial y cada reserva guarda la versión con que se calculó, así que un cambio solo afecta a reservas **nuevas**.

Vigente hoy (MVP): 15 % al propietario, 8 % al arrendatario, IVA **pendiente de contador**, pago al propietario a 2 días hábiles.

Ver la versión vigente y el historial:

```sql
select version, owner_fee_rate, renter_service_fee_rate, tax_treatment, payout_delay_business_days, effective_from, notes
from public.economic_config_versions order by effective_from desc;
```

Publicar una versión nueva (ejemplo: 12 % propietario y 8 % arrendatario desde ya). Las tasas van como decimal (0.12 = 12 %) y el motivo es obligatorio:

```sql
set request.jwt.claim.role = 'service_role';
select public.publish_economic_config('2027-01-promo', 0.12, 0.08, 2, 'Promoción de verano aprobada por Antonio');
```

### Garantías (las define RUÉ, no el propietario)

Vigentes: moto $150.000 · auto $250.000 · SUV y camioneta $350.000 · van y furgón $450.000 · minibús $600.000 · camión, remolque y especial $800.000.

```sql
select vehicle_type, amount_clp, version, effective_from, notes
from public.guarantee_rules order by vehicle_type, effective_from desc;
```

Cambiar la garantía de un tipo (solo reservas nuevas):

```sql
set request.jwt.claim.role = 'service_role';
select public.publish_guarantee_rule('car', 300000, '2027-01', 'Subimos garantía de autos por siniestralidad');
```

Hoy la garantía **se muestra pero no se cobra** por la app (falta definir con Transbank cómo bloquear el cupo).

### Plazos y exigencias

```sql
select key, value, description from public.platform_settings order by key;
```

Cada cambio en `platform_settings` queda registrado en `platform_settings_history` (qué, antes, después y cuándo).

Exigir licencia verificada para arrendar (recomendado al lanzar):

```sql
update public.platform_settings set value = 'true' where key = 'require_verified_license';
```

Exigir que cada vehículo acredite dominio antes de publicarse (cláusula 4 de los Términos; **obligatorio al lanzar**):

```sql
update public.platform_settings set value = 'true' where key = 'require_vehicle_verification';
```

## 3. Activar notificaciones push (una sola vez)

```sql
update public.platform_settings set value = '"https://<tu-proyecto>.supabase.co"' where key = 'supabase_url';
```

## 4. Revisar verificaciones de licencia y cédula

Pendientes:

```sql
select v.id, p.display_name, u.email, v.kind, v.front_path, v.back_path, v.created_at
from public.verification_requests v
join public.profiles p on p.id = v.user_id
join auth.users u on u.id = v.user_id
where v.status = 'pendiente'
order by v.created_at;
```

Para ver las fotos: **Storage → documents →** abre la carpeta del usuario (su id) y el archivo de `front_path` / `back_path`.

Revisa que: el nombre coincida con el de la cuenta, el documento esté vigente, la licencia sea de la clase adecuada (B para autos, camionetas y SUV; C para motos; clases profesionales A para transporte y camiones) y la foto sea legible.

Aprobar:

```sql
select public.review_verification('<id-de-la-solicitud>', true, null);
```

Rechazar (el mensaje le llega a la persona):

```sql
select public.review_verification('<id-de-la-solicitud>', false, 'La foto está borrosa. Tómala de nuevo con buena luz.');
```

## 4 b. Verificar que el vehículo es del arrendador (cláusula 4)

Pendientes:

```sql
select vv.id, v.title, v.plate, p.display_name, u.email, vv.cav_issued_on, vv.cav_path, vv.padron_path, vv.created_at,
       p.identity_verified as cedula_verificada
from public.vehicle_verifications vv
join public.vehicles v on v.id = vv.vehicle_id
join public.profiles p on p.id = vv.owner_id
join auth.users u on u.id = vv.owner_id
where vv.status = 'pendiente'
order by vv.created_at;
```

Revisa en **Storage → documents →** carpeta del usuario:

1. Que el **Certificado de Anotaciones Vigentes** sea auténtico: valida su código en el sitio del Registro Civil (verificación de certificados).
2. Que el **nombre y RUT del propietario** del certificado coincidan con la cédula verificada del usuario (`cedula_verificada` debe ser `true`; si no, pídele que verifique su cédula primero).
3. Que la **patente** coincida con la publicación.
4. Que no tenga anotaciones incompatibles con el arriendo (prohibiciones, embargos, encargo por robo). No todas las anotaciones impiden arrendar: si tienes dudas, consúltalo.

Aprobar (queda verificado por 6 meses):

```sql
select public.review_vehicle_verification('<id>', true, null);
```

Rechazar:

```sql
select public.review_vehicle_verification('<id>', false, 'El RUT del certificado no coincide con tu cédula.');
```

Cada día a las 7:15 el sistema quita la verificación a los vehículos cuyo plazo venció, los pausa (si la exigencia está activa) y avisa al propietario.

## 5. Pagar a los propietarios (T+2 días hábiles)

Cuando el propietario marca la reserva pagada como **devuelta**, se crea su pago con estado `pending` y fecha `eligible_on` = 2 días hábiles después. Cada hora el sistema pasa a `eligible` los que ya cumplieron la fecha. Estados:

| Estado | Qué significa |
|---|---|
| `pending` | Esperando los 2 días hábiles |
| `eligible` | Listo para transferir |
| `scheduled` | Transferencia preparada en tu banco (opcional) |
| `paid` | Transferido |
| `held` | Retenido (disputa, daño reportado, revisión, etc.) |
| `failed` | La transferencia rebotó |

Los bloques que usan `select public.…` empiezan con `set request.jwt.claim.role = 'service_role';`: esa línea le dice a la base que eres el administrador. Pégala siempre junto con el bloque.

Listos para transferir, con los datos bancarios:

```sql
select po.id, po.amount_clp, po.eligible_on, p.display_name,
       a.holder_name, a.holder_rut, a.bank, a.account_type, a.account_number, a.email
from public.payouts po
join public.profiles p on p.id = po.owner_id
left join public.payout_accounts a on a.user_id = po.owner_id
where po.status in ('eligible', 'scheduled')
order by po.eligible_on;
```

Si `holder_name` sale vacío, el propietario no ha cargado su cuenta: escríbele para que la complete en **Perfil → Datos bancarios**.

Después de transferir desde tu banco (queda registrado en el libro contable interno):

```sql
set request.jwt.claim.role = 'service_role';
select public.mark_payout_paid('<id-del-pago>', '<número de comprobante>');
```

Otros:

```sql
set request.jwt.claim.role = 'service_role';
select public.schedule_payout('<id>');                                   -- transferencia preparada
select public.hold_payout('<id>', 'damage_reported', 'Rayón en puerta');  -- retener
select public.release_payout('<id>', 'Revisado: sin daños');              -- liberar
select public.mark_payout_failed('<id>', 'Cuenta cerrada');               -- rebotó
```

Motivos de retención: `damage_reported`, `open_dispute`, `late_return`, `unpaid_extra_charge`, `fraud_review`, `payment_issue`. Una disputa retiene el pago sola; una reserva cancelada después del pago también.

**Feriados:** el cálculo de días hábiles salta sábados, domingos y los feriados de la tabla `business_holidays` (vienen los de fecha fija de 2026 y 2027). Agrega cada año los movibles:

```sql
insert into public.business_holidays (day, name) values ('2026-06-29', 'San Pedro y San Pablo');
```

## 6. Reportes de usuarios

```sql
select r.id, r.reason, r.details, r.status, r.created_at,
       rep.display_name as reporta, tgt.display_name as reportado, r.target_vehicle_id, r.booking_id
from public.reports r
join public.profiles rep on rep.id = r.reporter_id
left join public.profiles tgt on tgt.id = r.target_user_id
where r.status <> 'cerrado'
order by r.created_at;
```

Pausar una publicación problemática:

```sql
update public.vehicles set status = 'pausado' where id = '<id-del-vehículo>';
```

Cerrar el reporte:

```sql
update public.reports set status = 'cerrado' where id = '<id-del-reporte>';
```

Suspender a un usuario: **Authentication → Users →** busca su correo **→ ⋯ → Ban user**.

## 7. Reservas en disputa

```sql
select b.id, b.status, b.start_date, b.end_date, b.total_clp, o.display_name as propietario, r.display_name as arrendatario
from public.bookings b
join public.profiles o on o.id = b.owner_id
join public.profiles r on r.id = b.renter_id
where b.status = 'disputada';
```

Revisa el chat de la reserva:

```sql
select m.created_at, p.display_name, m.body
from public.messages m join public.profiles p on p.id = m.sender_id
where m.booking_id = '<id-de-la-reserva>' order by m.created_at;
```

Resolver (solo `finalizada` o `cancelada`; el sistema bloquea cualquier otro salto):

```sql
update public.bookings set status = 'finalizada' where id = '<id-de-la-reserva>';
-- o, si corresponde devolver el dinero:
update public.bookings set status = 'cancelada' where id = '<id-de-la-reserva>';
```

## 7 b. Comunicar datos de un arrendatario a un arrendador o abogado (cláusulas 17 y 18)

Solo si:
- El arrendatario aceptó la **casilla C** en esa reserva (desde la versión 2026-10-01 es obligatoria para reservar, así que todas las reservas nuevas la tienen), o existe otra base legal, por ejemplo una orden judicial.
- Hay **antecedentes verificables**: actas, fotos, chat o denuncia.
- El solicitante acreditó su identidad y su calidad de arrendador o de abogado.

¿Aceptó la casilla C?

```sql
select terms_version, terms_accepted, data_sharing_accepted, created_at
from public.booking_consents where booking_id = '<id-de-la-reserva>';
```

Datos que se pueden entregar: nombre completo, RUT, domicilio declarado, correo, teléfono y antecedentes de esa reserva. **Nunca** datos bancarios, claves ni información de otras reservas. La cédula o licencia solo si es imprescindible, y con los campos no pertinentes tapados.

Envíalos por un canal seguro y **regístralo siempre**:

```sql
insert into public.data_disclosures (booking_id, subject_user_id, recipient_name, recipient_role, data_shared, reason, subject_notified, created_by)
values ('<id-reserva>', '<id-arrendatario>', '<nombre de quien recibe>', 'arrendador', 'nombre, RUT, correo, teléfono, actas', '<motivo y antecedentes>', true,
        (select id from auth.users where email = '<tu-correo>'));
```

Avísale al titular (el arrendatario) que se comunicaron sus datos, salvo que la ley lo impida.

## 8. Reembolsos

Si alguien paga una reserva que ya no se podía pagar (vencida, cancelada o pagada dos veces), **el sistema anula el cargo automáticamente** y le avisa.

Otros reembolsos (por ejemplo, una cancelación acordada) se hacen en el **Portal de Comercios de Transbank → Transacciones →** busca la orden de compra **→ Anular**. La orden de compra de cada reserva:

```sql
select buy_order, amount_clp, status, payment_type, installments, created_at
from public.payments where booking_id = '<id-de-la-reserva>' order by created_at;
```

Después cancela la reserva (bloque del punto 7) si no estaba cancelada, y registra el reembolso en el libro interno:

```sql
set request.jwt.claim.role = 'service_role';
select public.record_manual_refund('<id-de-la-reserva>', <monto>, '<código de anulación de Transbank>');
```

Cuando Transbank te liquide, puedes registrar su comisión por reserva (sirve para calcular el ingreso neto):

```sql
set request.jwt.claim.role = 'service_role';
select public.record_processing_cost('<id-de-la-reserva>', <monto>, '<referencia de la liquidación>');
```

Pagos que requieren revisión manual (la anulación automática falló):

```sql
select e.created_at, e.event_key, e.payload ->> 'buy_order' as orden, e.error
from public.payment_events e
where e.provider = 'webpay' and e.error like '%anulación pendiente%'
order by e.created_at desc;
```

## 9. Números del negocio

Resumen de un período (fechas de Chile). GMV = arriendos pagados antes de comisiones (sin garantía ni cargo de servicio); ingreso bruto = comisión 15 % + cargo 8 %; take rate = ingreso / GMV:

```sql
set request.jwt.claim.role = 'service_role';
select jsonb_pretty(public.marketplace_summary('2026-10-01', '2026-10-31'));
```

Detalle por reserva (montos congelados, versión de comisiones, reembolsos, estado del pago al propietario):

```sql
select * from public.booking_financials order by created_at desc limit 50;
```

El ingreso neto y el IVA aparecen vacíos hasta que el contador defina el tratamiento tributario. Eso es intencional: no se inventan.

Eventos del negocio (búsquedas, búsquedas sin resultado, reservas, pagos, devoluciones):

```sql
select event_type, count(*) from public.domain_events
where occurred_at >= now() - interval '7 days' group by 1 order by 2 desc;
```

## 10. Salud del sistema

Tareas automáticas (vencimientos cada 10 minutos):

```sql
select jobname, schedule, active from cron.job;
select status, return_message, start_time from cron.job_run_details order by start_time desc limit 10;
```

Errores de pagos y funciones: **Edge Functions → (función) → Logs**.
