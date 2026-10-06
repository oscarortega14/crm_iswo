# frozen_string_literal: true

module DuplicateFlags
  # ==========================================================================
  # DuplicateFlags::Merge — resuelve una alerta fusionando
  # ==========================================================================
  # Fusiona la oportunidad nueva en la existente y, si son de contactos
  # distintos, también los contactos (queda uno solo con todos sus orígenes).
  # Lo usan la fusión individual y la masiva de /duplicates.
  # ==========================================================================
  module Merge
    module_function

    def call(flag:, by:, note: nil)
      source = flag.opportunity
      target = flag.duplicate_of_opportunity
      ActiveRecord::Base.transaction do
        Opportunities::Merger.new(source: source, target: target, performed_by: by).call
        if source.contact_id != target.contact_id
          Contacts::Merger.call(survivor: target.contact, absorbed: source.contact, performed_by: by)
        end
        flag.resolve!(as: "merged", by: by, note: note)
      end
    end
  end
end
