# frozen_string_literal: true

class WhatsappTemplateSerializer < ApplicationSerializer
  set_type :whatsapp_template

  attributes :name, :meta_template_name, :language, :variable_labels, :variable_names, :active
end
