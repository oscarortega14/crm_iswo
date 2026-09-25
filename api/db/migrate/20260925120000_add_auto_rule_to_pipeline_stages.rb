# frozen_string_literal: true

# Reglas de avance automático por etapa (Opportunities::StageAutomation).
# Backfill: las etapas "Calificada" existentes reciben la regla bant_qualified
# para conservar el auto-avance BANT que antes dependía del nombre.
class AddAutoRuleToPipelineStages < ActiveRecord::Migration[8.1]
  def up
    add_column :pipeline_stages, :auto_rule, :jsonb, default: {}, null: false,
               comment: "Regla de auto-avance: { trigger: whatsapp_outbound | whatsapp_inbound | bant_qualified }"

    # RLS (Fase 3): el backfill cruza todos los tenants.
    execute "SET LOCAL crm.bypass_rls = 'on'"
    execute <<~SQL.squish
      UPDATE pipeline_stages
      SET auto_rule = '{"trigger": "bant_qualified"}'::jsonb
      WHERE lower(name) = 'calificada'
        AND closed_won = FALSE AND closed_lost = FALSE
        AND discarded_at IS NULL
    SQL
  end

  def down
    remove_column :pipeline_stages, :auto_rule
  end
end
