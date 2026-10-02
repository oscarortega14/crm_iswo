# frozen_string_literal: true

# Baja de correos de marketing (Ley 1581 / reglas de Gmail y Yahoo): quien se da
# de baja, rebota de forma permanente o marca como spam no vuelve a recibir
# campañas de correo. No afecta WhatsApp ni los correos del sistema.
class AddEmailOptOutToContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :contacts, :email_opt_out_at, :datetime
    add_column :contacts, :email_opt_out_source, :string,
               comment: "unsubscribe | bounce | complaint | manual"
    add_index :contacts, :email_opt_out_at
  end
end
