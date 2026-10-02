# frozen_string_literal: true

class EmailCampaignSerializer < ApplicationSerializer
  set_type :email_campaign

  attributes :name, :subject, :preheader, :audience_filters, :status, :scheduled_at, :batch_size,
             :total_recipients, :sent_count, :failed_count, :skipped_count,
             :started_at, :completed_at, :last_batch_at, :created_at, :updated_at

  # El contenido completo solo en el detalle (show/create/update), no en el listado.
  attribute :body_html, if: proc { |_c, params| params[:full] } do |c|
    c.body_html
  end

  attribute :body_design, if: proc { |_c, params| params[:full] } do |c|
    c.body_design
  end

  attribute :created_by_name do |c|
    c.created_by_user&.name
  end

  attribute :result_stats do |c|
    c.status_draft? || c.status_scheduled? ? nil : c.result_stats
  end
end
