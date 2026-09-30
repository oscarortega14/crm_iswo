# frozen_string_literal: true

# Restaura contactos eliminados (soft-delete) que volvieron a escribir por
# WhatsApp DESPUÉS de ser eliminados: sus mensajes nuevos quedaron colgados de
# un contacto eliminado y la bandeja no podía responderles. Desde ahora
# WebhookProcessorJob#upsert_contact los restaura al llegar el mensaje.
# Idempotente; los contactos eliminados sin mensajes posteriores no se tocan.
class RestoreContactsThatWroteAfterDeletion < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL crm.bypass_rls = 'on'" # RLS (Fase 3): cruza todos los tenants
    restored = select_value(<<~SQL.squish)
      WITH restored AS (
        UPDATE contacts SET discarded_at = NULL, updated_at = NOW()
        WHERE contacts.discarded_at IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM whatsapp_messages m
            WHERE m.contact_id = contacts.id
              AND m.direction = 'in'
              AND m.created_at > contacts.discarded_at
          )
        RETURNING 1
      )
      SELECT COUNT(*) FROM restored
    SQL
    say "Contactos restaurados (volvieron a escribir tras ser eliminados): #{restored}"
  end

  def down
    # Irreversible a propósito: no se sabe qué contactos estaban eliminados antes.
  end
end
