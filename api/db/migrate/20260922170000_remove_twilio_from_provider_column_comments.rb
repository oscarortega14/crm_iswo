# frozen_string_literal: true

# Actualiza el comentario documental de `provider` (no cambia datos ni
# validaciones) tras remover Twilio como proveedor de WhatsApp soportado.
class RemoveTwilioFromProviderColumnComments < ActiveRecord::Migration[8.1]
  def up
    change_column_comment :ad_integrations, :provider, "meta | google | whatsapp_cloud | openwa"
    change_column_comment :whatsapp_messages, :provider, "whatsapp_cloud | openwa"
  end

  def down
    change_column_comment :ad_integrations, :provider, "meta | google | twilio | whatsapp_cloud"
    change_column_comment :whatsapp_messages, :provider, "twilio | whatsapp_cloud"
  end
end
