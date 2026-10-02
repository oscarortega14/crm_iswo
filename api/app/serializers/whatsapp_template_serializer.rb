# frozen_string_literal: true

class WhatsappTemplateSerializer < ApplicationSerializer
  set_type :whatsapp_template

  attributes :name, :meta_template_name, :language, :variable_labels, :variable_names, :active, :opt_in_request,
             :category, :meta_status, :meta_template_id, :meta_synced_at
end
