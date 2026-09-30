# frozen_string_literal: true

# Historial de orígenes del contacto: cada vía por la que llegó (creación
# manual, importación, landing, Meta/Google Ads, WhatsApp, blog…), incluida
# la de los contactos que se le fusionaron. `source_kind`/`source_label`
# siguen siendo el origen original.
#   [{ "kind": "import", "label": "Excel: base.xlsx", "at": "2026-09-20T10:00:00Z" }, …]
class AddOriginsToContacts < ActiveRecord::Migration[8.1]
  def up
    add_column :contacts, :origins, :jsonb, default: [], null: false,
               comment: "Orígenes del contacto [{kind, label, at}] (incluye los de contactos fusionados)"

    execute "SET LOCAL crm.bypass_rls = 'on'" # RLS (Fase 3): backfill en todos los tenants
    execute <<~SQL.squish
      UPDATE contacts
      SET origins = jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'kind', source_kind, 'label', NULLIF(source_label, ''), 'at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )))
      WHERE source_kind IS NOT NULL AND source_kind <> ''
    SQL
  end

  def down
    remove_column :contacts, :origins
  end
end
