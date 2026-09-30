# frozen_string_literal: true

class AddMetaSyncFieldsToWhatsappTemplates < ActiveRecord::Migration[8.1]
  def change
    # Campos que solo el botón "Sincronizar" (WhatsApp::TemplateSync) escribe —
    # nunca se editan a mano. category/meta_status vienen tal cual de Meta
    # (ej. "MARKETING"/"UTILITY", "APPROVED"/"REJECTED"/"PENDING"); permiten
    # detectar en el catálogo local cuando algo cambió del lado de Meta sin
    # pasar por el CRM (motivo de esta feature: una plantilla rechazada como
    # Utility y reaprobada como Marketing directamente en Meta Business Suite).
    add_column :whatsapp_templates, :category,         :string
    add_column :whatsapp_templates, :meta_status,       :string
    add_column :whatsapp_templates, :meta_template_id,  :string
    add_column :whatsapp_templates, :meta_synced_at,    :datetime
  end
end
