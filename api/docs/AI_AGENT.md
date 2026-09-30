# Asistente IA de WhatsApp (agente — opción 2)

Responde por WhatsApp con la información del negocio, califica al lead, guarda sus datos y le pasa la
conversación a un asesor cuando hace falta. Pantalla: **Ajustes → Asistente IA** (admin edita, manager consulta).

## Fases

| Fase | Estado | Qué hace |
|---|---|---|
| 1. Conversa y califica | ✅ | Responde, califica (frío/tibio/caliente), guarda datos, pasa a asesor, «Mensaje al autorizar» en campañas, filtro «Autorizaron» en la bandeja |
| 2. Agenda | pendiente | Google Calendar: disponibilidad, agendar, cancelar, reprogramar |
| 3. Recordatorios | pendiente | Recordatorio de cita al cliente con plantilla aprobada por Meta |

## Cómo funciona

| Pieza | Dónde |
|---|---|
| Mensaje entrante → espera 8 s (ráfagas) → automatizaciones | `WhatsappMessage#schedule_inbound_automation` → `WhatsappInboundAutomationJob` |
| «Sí» a una campaña con «Mensaje al autorizar» | `WhatsApp::ConfirmationFollowup` (texto fijo, una vez por destinatario) |
| Respuesta del asistente | `AiAgent::Responder` (instrucciones + info del negocio + últimos 20 mensajes de 7 días) |
| Herramientas del CRM | `AiAgent::Tools`: `calificar_lead`, `guardar_datos_contacto`, `pasar_a_asesor` |
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

## Costo

Cada respuesta consume ~1.500 tokens de entrada y ~60 de salida (varía con la información del negocio y el
historial). La pantalla muestra el consumo y un costo aproximado de los últimos 30 días.
