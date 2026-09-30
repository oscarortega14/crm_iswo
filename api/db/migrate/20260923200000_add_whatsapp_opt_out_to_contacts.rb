# frozen_string_literal: true

class AddWhatsappOptOutToContacts < ActiveRecord::Migration[8.1]
  def change
    # Negativa explícita a recibir WhatsApp ("No autorizo", "stop"…). A
    # diferencia de `whatsapp_opt_in_at: nil` (nunca se pidió / no se sabe),
    # esto registra que el contacto DIJO que no — evidencia para Habeas Data
    # (Ley 1581) y bloqueo para campañas, incluso las de solicitud de opt-in.
    # Solo un "Sí" explícito o un opt-in manual lo limpia.
    add_column :contacts, :whatsapp_opt_out_at, :datetime
    add_column :contacts, :whatsapp_opt_out_source, :string, comment: "reply | manual"
    add_index  :contacts, :whatsapp_opt_out_at
  end
end
