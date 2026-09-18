# frozen_string_literal: true

# ============================================================================
# ContactSerializer
# ============================================================================
# El teléfono se expone normalizado (E.164) y su versión mostrable.
# Los custom_fields se devuelven tal cual (el SPA los pinta dinámicamente).
# ============================================================================
class ContactSerializer < ApplicationSerializer
  set_type :contact

  attributes :kind, :first_name, :last_name, :email,
             :company, :position, :city, :country,
             :notes, :custom_fields, :discarded_at

  attribute :phone_e164 do |c|
    c.phone_e164_safe
  end

  attribute :document_id do |c|
    c.document_id_safe
  end

  attribute :owner_name do |c|
    c.owner_user&.name
  end

  attribute :owner_user_id do |c|
    c.owner_user_id&.to_s
  end

  attribute :data_classification do |c|
    c.class.data_classification
  end

  attribute :source_kind do |c|
    c.has_attribute?(:source_kind) ? c[:source_kind] : nil
  end

  attribute :source_label do |c|
    c.has_attribute?(:source_label) ? c[:source_label] : nil
  end

  attribute :last_contacted_at do |c|
    c.respond_to?(:last_contacted_at) ? c.last_contacted_at : nil
  end

  attribute :whatsapp_opted_in do |c|
    c.whatsapp_opted_in?
  end

  attribute :whatsapp_opt_in_source, &:whatsapp_opt_in_source

  attribute :full_name do |c|
    [c.first_name, c.last_name].compact.join(" ").strip.presence || c.company.presence || "—"
  end

  attribute :phone_display, &:phone_display_value

  attribute :opportunities_count do |c, params|
    scope = c.opportunities.kept
    user  = params&.dig(:current_user)
    if user&.role == "consultant"
      scope = scope.where(owner_user_id: user.id)
    end
    scope.count
  end

  attribute :can_edit do |c, params|
    user = params&.dig(:current_user)
    next false unless user

    ContactPolicy.new(user, c).update?
  end

  attribute :landing_origins, if: ->(_r, params) { params && params[:include_landing_origins] } do |c|
    subs = if c.association(:landing_form_submissions).loaded?
             c.landing_form_submissions
           else
             c.landing_form_submissions.includes(:landing_page).order(created_at: :desc).limit(10)
           end
    subs.sort_by { |s| -s.created_at.to_i }.first(10).map do |s|
      {
        id:              s.id.to_s,
        landing_page_id: s.landing_page_id.to_s,
        landing_title:   s.landing_page&.title,
        landing_slug:    s.landing_page&.slug,
        opportunity_id:  s.opportunity_id&.to_s,
        created_at:      s.created_at&.iso8601
      }
    end
  end

  belongs_to :owner_user, serializer: :user, record_type: :user
  belongs_to :tenant,     serializer: :tenant
end
