# frozen_string_literal: true

# ============================================================================
# EmailCampaignPolicy — correo masivo, solo admin/manager (igual que las
# campañas de WhatsApp y /exports). El remitente (dominio) lo configura el admin.
# ============================================================================
class EmailCampaignPolicy < ApplicationPolicy
  def index?   = manager_or_admin?
  def show?    = manager_or_admin?
  def create?  = manager_or_admin?
  def update?  = manager_or_admin?
  def destroy? = manager_or_admin?

  # Remitente de campañas (dominio propio en SES).
  def manage_sender? = admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user
      return scope.all if admin? || manager?

      scope.none
    end
  end
end
