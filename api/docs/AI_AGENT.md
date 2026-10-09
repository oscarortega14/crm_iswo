# Asistente IA de WhatsApp (agente — opción 2)

Responde por WhatsApp con la información del negocio, califica al lead, guarda sus datos y le pasa la
conversación a un asesor cuando hace falta. Pantalla: **Ajustes → Asistente IA** (admin edita, manager consulta).

## Fases

| Fase | Estado | Qué hace |
|---|---|---|
| 1. Conversa y califica | ✅ | Responde, califica (frío/tibio/caliente), guarda datos, pasa a asesor, «Mensaje al autorizar» en campañas, filtro «Autorizaron» en la bandeja |
| 2. Agenda | ✅ | Google Calendar: horarios libres, agendar, reprogramar y cancelar citas; disparador de etapa «Se agendó una reunión» |
| 3. Recordatorios | ✅ | Recordatorios al cliente (WhatsApp y correo), «Confirmo / Reprogramar», recordatorio al asesor, resumen diario y «no asistió» → ofrecer reagendar |

## Cómo funciona

| Pieza | Dónde |
|---|---|
| Mensaje entrante → espera 8 s (ráfagas) → automatizaciones | `WhatsappMessage#schedule_inbound_automation` → `WhatsappInboundAutomationJob` |
| «Sí» a una campaña con «Mensaje al autorizar» | `WhatsApp::ConfirmationFollowup` (texto fijo, una vez por destinatario) |
| Respuesta del asistente | `AiAgent::Responder` (instrucciones + info del negocio + últimos 20 mensajes de 7 días) |
| Herramientas del CRM | `AiAgent::Tools`: `calificar_lead`, `guardar_datos_contacto`, `pasar_a_asesor` y, con agenda, `consultar_disponibilidad`, `agendar_cita`, `reprogramar_cita`, `cancelar_cita` |
| Agenda | `AiAgent::Scheduler` (horario de atención, duración, anticipación, ocupado en Google + citas del CRM) y `AiAgent::GoogleCalendar` (cuenta de servicio) |
| Citas | `appointments` (Ajustes → Asistente IA → Próximas citas) |
| Modelo | `AiAgent::OpenaiClient` (Chat Completions con herramientas) |
| Registro y costo | `ai_agent_runs` (tokens de entrada/salida, herramientas usadas, errores) |

Reglas de seguridad:

- **No responde** si:
  - el asistente está apagado o sin información del negocio;
  - falta la clave;
  - el chat está en pausa;
  - el contacto dijo «No».
- **Límite diario** de 40 respuestas por contacto.
- En una **ráfaga de mensajes** responde solo al último.
- **Una persona que escribe desde el CRM pausa el asistente** en ese chat. Se reanuda con el botón «Asistente en pausa» de la bandeja.
- Los mensajes del asistente, de las campañas y de los avisos de recordatorio se guardan con `automated = true`. No cuentan como respuesta de una persona.
- Solo responde a mensajes recientes del cliente, dentro de la ventana de 24 h de WhatsApp, así que usa texto libre sin plantilla.

## Configuración en el servidor

```sh
dokku config:set crm-iswo-api OPENAI_API_KEY=sk-...
# opcionales
dokku config:set crm-iswo-api OPENAI_MODEL=gpt-4.1-mini      # por defecto gpt-4.1-mini
dokku config:set crm-iswo-api OPENAI_BASE_URL=https://...     # proxy / endpoint compatible
```

Sin `OPENAI_API_KEY` se puede dejar todo configurado; el asistente empieza a responder cuando se agrega.

## Agenda: Google Calendar con cuenta de servicio (una vez)

1. En [Google Cloud Console](https://console.cloud.google.com/), crea o elige un proyecto y habilita **Google Calendar API**.
2. Ve a **IAM y administración → Cuentas de servicio → Crear cuenta de servicio**. No necesita roles.
3. En la cuenta, abre **Claves → Agregar clave → JSON** y se descarga el archivo.
4. Configúralo en el servidor; se puede pasar en base64 para evitar problemas con comillas:

   ```sh
   dokku config:set crm-iswo-api GOOGLE_SERVICE_ACCOUNT_JSON="$(base64 -w0 cuenta-servicio.json)"
   ```

5. En **Ajustes → Asistente IA → Agenda**, el CRM muestra el correo de la cuenta de servicio. En Google Calendar, cada empresa:
   - abre **Configuración del calendario → Compartir con personas específicas**;
   - agrega ese correo con permiso **«Hacer cambios en los eventos»**.
6. En la misma pantalla:
   - escribe el **ID del calendario**: el correo del calendario, o el ID que aparece en «Integrar el calendario»;
   - fija el horario de atención, la duración, la anticipación y el lugar o enlace;
   - pulsa **Probar conexión**.
7. Opcional: en **Ajustes → Pipelines**, en la etapa que corresponda (p. ej. «Reunión agendada»), elige el avance automático **«Se agendó una reunión (asistente IA)»**.

Los eventos se crean sin enviar invitaciones (`sendUpdates=none`). Al cliente se le confirma por WhatsApp.

## Costo

Cada respuesta consume ~1.500 tokens de entrada y ~60 de salida (varía con la información del negocio y el
historial). La pantalla muestra el consumo y un costo aproximado de los últimos 30 días.

## Recordatorios de citas (fase 3)

| Pieza | Dónde |
|---|---|
| Recordatorios al cliente (cada 5 min) | `AppointmentReminderJob` → `AiAgent::AppointmentReminders` |
| «Confirmo» / «Reprogramar» | `AiAgent::AppointmentReplies` (dentro de `WhatsappInboundAutomationJob`) |
| Recordatorio al asesor | módulo Recordatorios (`Reminder`), lo crea `AiAgent::Scheduler` al agendar |
| Resumen diario (7:00 a. m.) | `AppointmentDailySummaryJob` → campana + correo a admin/manager |
| Correos al cliente | `AppointmentMailer` (desde el dominio verificado del email marketing si existe) |

Reglas:

- **Por WhatsApp:**
  - si el cliente escribió en las últimas 24 h, el recordatorio va como texto libre, sin costo de plantilla;
  - si no, se usa la plantilla elegida en Ajustes → Asistente IA (categoría **Utilidad**; variables `{{1}}` nombre y `{{2}}` fecha y hora);
  - sin plantilla y con la ventana cerrada, no se envía WhatsApp; el correo sí, si está activado.
- Un recordatorio se **omite** si la cita se agendó con menos anticipación que ese recordatorio.
- **«Confirmo»** marca la cita como confirmada y avisa al asesor. **«Reprogramar»** lo atiende el asistente (si está activo) o se avisa al asesor.
- **«No asistió»**, al marcarlo en Citas, envía el mensaje para reagendar por WhatsApp (texto libre o la plantilla de «no asistió») y por correo.
