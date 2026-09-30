# frozen_string_literal: true

class AddOptInRequestToWhatsappTemplates < ActiveRecord::Migration[8.1]
  def change
    # Marca una plantilla como "solicitud de opt-in": el gate de opt-in de
    # WhatsappCampaign (launch! + Dispatcher) se salta para campañas que usan
    # una plantilla así marcada — es la única forma de contactar por WhatsApp
    # a alguien que todavía no dio consentimiento, pidiéndoselo primero.
    # Debe marcarse a mano, una vez, sobre una plantilla ya aprobada por Meta
    # específicamente redactada para pedir autorización (ver docs/).
    add_column :whatsapp_templates, :opt_in_request, :boolean, null: false, default: false
  end
end
