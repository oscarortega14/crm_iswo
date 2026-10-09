# frozen_string_literal: true

# «Mensaje al autorizar»: quien responde «Sí» a una campaña recibe al instante
# un mensaje automático (texto libre, dentro de la ventana de 24 h que abre su
# propia respuesta), sin importar si autoriza a los 5 minutos o a los 3 días.
class AddConfirmationFollowupToWhatsappCampaigns < ActiveRecord::Migration[8.1]
  def change
    add_column :whatsapp_campaigns, :confirm_reply_body, :text,
               comment: "mensaje automático a quien responde «Sí»; admite {{nombre}}"

    add_column :whatsapp_campaign_recipients, :confirmed_at, :datetime,
               comment: "respondió «Sí» a esta campaña"
    add_reference :whatsapp_campaign_recipients, :confirm_reply_message,
                  foreign_key: { to_table: :whatsapp_messages }, index: true

    add_column :whatsapp_messages, :automated, :boolean, null: false, default: false,
               comment: "enviado por una automatización (no por una persona)"

    add_column :contacts, :whatsapp_automation_paused_at, :datetime,
               comment: "un asesor tomó el control del chat: no enviar respuestas automáticas"
  end
end
