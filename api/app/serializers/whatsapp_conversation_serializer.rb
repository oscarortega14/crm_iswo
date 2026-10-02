# frozen_string_literal: true

# ============================================================================
# WhatsappConversationSerializer
# ============================================================================
# Serializa el ÚLTIMO WhatsappMessage de cada contacto como si fuera una
# "conversación" (bandeja de entrada). Recibe por params:
#   - unread_counts: { contact_id => count } precalculado (evita N+1)
#   - current_user: para calcular `bucket` (mine/network/unassigned/other)
# ============================================================================
class WhatsappConversationSerializer < ApplicationSerializer
  set_type :whatsapp_conversation

  attribute :contact_id do |m|
    m.contact_id&.to_s
  end

  attribute :contact_name do |m|
    m.contact&.display_name
  end

  attribute :contact_phone do |m|
    m.contact&.phone_e164_safe
  end

  attribute :opportunity_id do |m|
    m.opportunity_id&.to_s
  end

  attribute :opportunity_stage do |m|
    m.opportunity&.pipeline_stage&.name
  end

  attribute :owner_user_id do |m|
    (m.opportunity&.owner_user_id || m.contact&.owner_user_id)&.to_s
  end

  attribute :owner_name do |m|
    (m.opportunity&.owner_user || m.contact&.owner_user)&.name
  end

  # Las plantillas no guardan `body` (Meta no lo devuelve) — igual que en la
  # burbuja del chat (WhatsAppThread.tsx), si no hay body mostramos
  # "Plantilla: <nombre> (<params>)" para no dejar el preview en blanco.
  attribute :last_message_body do |m|
    m.body.presence || WhatsappConversationSerializer.template_preview(m)
  end
  attribute :last_message_direction, &:direction
  attribute :last_message_status,    &:status
  attribute :last_message_at,        &:created_at

  attribute :unread_count do |m, params|
    params&.dig(:unread_counts)&.fetch(m.contact_id, 0) || 0
  end

  # Dijo «Sí» y ninguna persona le ha respondido (Contact.whatsapp_awaiting_reply).
  attribute :awaiting_reply do |m, params|
    params&.dig(:awaiting_ids)&.include?(m.contact_id) || false
  end

  attribute :automation_paused do |m|
    m.contact&.whatsapp_automation_paused? || false
  end

  attribute :bucket do |m, params|
    user = params&.dig(:current_user)
    owner_id = m.opportunity&.owner_user_id || m.contact&.owner_user_id

    if owner_id.nil?
      "unassigned"
    elsif owner_id == user&.id
      "mine"
    elsif user&.role == "consultant" && m.opportunity &&
          ConsultantNetworkAccess.can_view_opportunity?(user, m.opportunity)
      "network"
    else
      "other"
    end
  end

  def self.template_preview(m)
    return nil unless m.message_type == "template" && m.template_name.present?

    params = Array(m.template_params)
    params.any? ? "Plantilla: #{m.template_name} (#{params.join(', ')})" : "Plantilla: #{m.template_name}"
  end
end
