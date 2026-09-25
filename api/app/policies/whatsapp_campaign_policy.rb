# frozen_string_literal: true

# ============================================================================
# WhatsappCampaignPolicy — mensajería masiva, solo admin/manager
# ============================================================================
class WhatsappCampaignPolicy < ApplicationPolicy
  def index?   = manager_or_admin?
  def show?    = manager_or_admin?
  def create?  = manager_or_admin?
  def update?  = manager_or_admin?
  def destroy? = admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user
      return scope.all if admin? || manager?

      scope.none
    end
  end
end
