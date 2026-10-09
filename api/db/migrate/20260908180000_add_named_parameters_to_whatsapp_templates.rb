# frozen_string_literal: true

class AddNamedParametersToWhatsappTemplates < ActiveRecord::Migration[8.1]
  def change
    # Meta migró las plantillas nuevas a variables con nombre
    # (`{{primer_nombre}}` en vez de `{{1}}`). `variable_names[i]` es el
    # nombre exacto registrado en Meta para `variable_labels[i]`; si viene
    # vacío para una plantilla, se sigue enviando en formato posicional
    # (compatibilidad con plantillas ya aprobadas antes de este cambio).
    add_column :whatsapp_templates, :variable_names, :jsonb, null: false, default: []
    add_column :whatsapp_messages, :template_variable_names, :jsonb, null: false, default: []
  end
end
