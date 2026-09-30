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

## 2. Configurar comisiones y plazos

Ver valores actuales:

```sql
select key, value, description from public.platform_settings order by key;
```

Cambiar (ejemplo: 10 % de comisión al propietario y 5 % de cargo al arrendatario):

```sql
update public.platform_settings set value = '10', updated_at = now() where key = 'owner_commission_pct';
update public.platform_settings set value = '5',  updated_at = now() where key = 'renter_service_fee_pct';
```

Solo afecta a reservas **nuevas**; las ya creadas mantienen su precio.

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

## 5. Pagar a los propietarios

Cuando una reserva pagada se finaliza, se crea un pago pendiente al propietario.

Pendientes, con los datos bancarios:

```sql
select po.id, po.amount_clp, po.created_at, p.display_name,
       a.holder_name, a.holder_rut, a.bank, a.account_type, a.account_number, a.email
from public.payouts po
join public.profiles p on p.id = po.owner_id
left join public.payout_accounts a on a.user_id = po.owner_id
where po.status = 'pendiente'
order by po.created_at;
```

Si `holder_name` sale vacío, el propietario no ha cargado su cuenta: escríbele para que la complete en **Perfil → Datos bancarios**.

Después de transferir desde tu banco, márcalo como pagado:

```sql
update public.payouts
set status = 'pagado', paid_at = now(), reference = '<número de comprobante>'
where id = '<id-del-pago>';
```

Retener un pago (por ejemplo, si hay un reclamo abierto):

```sql
update public.payouts set status = 'retenido' where id = '<id-del-pago>';
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

Los reembolsos se hacen en **Mercado Pago → Tu negocio → Ventas →** busca el pago **→ Devolver dinero**. Después cancela la reserva (bloque del punto 7) si no estaba cancelada.

Pagos que llegaron cuando la reserva ya no se podía pagar (requieren devolución):

```sql
select e.created_at, e.event_key, e.error
from public.payment_events e
where e.error in ('not_payable', 'amount_mismatch')
order by e.created_at desc;
```

## 9. Salud del sistema

Tareas automáticas (vencimientos cada 10 minutos):

```sql
select jobname, schedule, active from cron.job;
select status, return_message, start_time from cron.job_run_details order by start_time desc limit 10;
```

Errores de pagos y funciones: **Edge Functions → (función) → Logs**.
