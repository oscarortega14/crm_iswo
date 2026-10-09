# Email marketing (AWS SES)

Campañas de correo desde el **dominio propio de cada empresa (tenant)**, con baja en
un clic y resultados por destinatario. Pantalla: **Email marketing** (`/email`, admin y manager).

## Cómo funciona

| Pieza | Dónde |
|---|---|
| Remitente por tenant (dominio, nombre, reply-to, dirección) | `EmailMarketing::Sender` → `tenant.settings["email_marketing"]` |
| Verificación del dominio (Easy DKIM) | `POST /api/v1/email_sender/verify` y `/refresh` → SES `CreateEmailIdentity` / `GetEmailIdentity` |
| Campañas y audiencia | `EmailCampaign`, `EmailCampaigns::AudienceResolver` (filtros de oportunidad + tipo de contacto) |
| Envío por lotes (cada minuto) | `EmailCampaignBatchJob` → `EmailCampaigns::Dispatcher` → SES `SendEmail` |
| Variables `{{nombre}}`, pie y texto plano | `EmailMarketing::Renderer` |
| Baja en un clic | `List-Unsubscribe` + `List-Unsubscribe-Post`; página `GET/POST /api/v1/public/email/unsubscribe?t=…` |
| Entregas, rebotes, quejas, aperturas, clics | SES configuration set → SNS → `POST /api/v1/webhooks/ses` → `SesEventJob` |

Nunca se envía a contactos con `email_opt_out_at` (baja, rebote permanente, queja o
baja manual). Las bajas manuales se pueden deshacer desde Contactos; las demás no.

## Configuración en AWS (una sola vez)

Región: la misma de `AWS_REGION` (la que ya usa ActionMailer).

1. **Salir del sandbox de SES** (Account dashboard → *Request production access*).
   En sandbox solo se entrega a correos verificados uno por uno.
2. **Permisos IAM** del rol/usuario del servidor, además de los que ya tiene para enviar:
   `ses:SendEmail`, `ses:CreateEmailIdentity`, `ses:GetEmailIdentity`.
3. **Tema SNS** (ej. `ses-marketing-events`) con una suscripción **HTTPS** a
   `https://iswocrm.com/api/v1/webhooks/ses`. El CRM confirma la suscripción solo.
4. **Configuration set** (ej. `marketing`) con un *event destination* hacia ese tema SNS
   y los eventos: Send, Delivery, Bounce, Complaint, Reject, Open, Click, Rendering failure.
5. Variables de entorno en Dokku:

   ```sh
   dokku config:set crm-iswo-api SES_MARKETING_CONFIGURATION_SET=marketing \
                                SES_SNS_TOPIC_ARN=arn:aws:sns:us-east-1:XXXXXXXXXXXX:ses-marketing-events
   ```

   Sin `SES_MARKETING_CONFIGURATION_SET` los envíos funcionan, pero los resultados se quedan en «Enviado».

## Configuración por empresa (desde el CRM)

1. Admin → **Email marketing → Remitente**: dominio (ej. `iswo.com.co`), correo que envía
   (`info`), nombre visible, correo de respuesta y dirección física (va en el pie).
2. **Verificar dominio** → el CRM muestra 3 registros **CNAME** (DKIM) y 1 **TXT** (DMARC).
3. Quien administra el DNS del dominio los crea. Luego **Ya los agregué, comprobar**
   (el DNS puede tardar de minutos a 72 h).
4. Con el estado **Verificado** ya se pueden enviar pruebas y lanzar campañas.

## Buenas prácticas

- Empezar con envíos pequeños (calentamiento del dominio) e ir subiendo.
- Mantener la tasa de quejas por debajo de 0,3 % (regla de Gmail/Yahoo).
- Solo enviar a contactos que autorizaron comunicaciones (Ley 1581 de 2012); el CRM
  pide confirmarlo al lanzar cada campaña.
