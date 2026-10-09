# frozen_string_literal: true

# ============================================================================
# AiAgentPolicy — asistente IA de WhatsApp (registro: :ai_agent)
# ============================================================================
# admin configura, activa y prueba; manager consulta la configuración y la
# actividad; consultor y visor no acceden (el consultor sí pausa/reanuda el
# asistente en sus chats desde la bandeja, ver WhatsappConversationsController).
# ============================================================================
class AiAgentPolicy < ApplicationPolicy
  def show?     = manager_or_admin?
  def activity? = manager_or_admin?
  def update?   = admin?
  def test?     = admin?
  # Agenda: ver próximas citas y cancelarlas (admin/manager); probar conexión (admin).
  def appointments?      = manager_or_admin?
  def cancel_appointment? = manager_or_admin?
end
