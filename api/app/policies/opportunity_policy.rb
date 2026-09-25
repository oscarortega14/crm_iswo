# frozen_string_literal: true

# ============================================================================
# OpportunityPolicy
# ============================================================================
# - admin/manager: ven y editan todas las oportunidades del tenant.
# - consultant: ve propias + red (RFC §6.3); edita solo las propias.
# - viewer: solo lectura sobre todas.
#
# Reasignar (assign) y mergear son acciones sensibles → solo admin/manager.
# ============================================================================
class OpportunityPolicy < ApplicationPolicy
  def index?            = staff?
  def show?             = staff? && (manager_or_admin? || viewer? || ConsultantNetworkAccess.can_view_opportunity?(user, record))
  def create?           = admin? || manager? || consultant?
  def update?           = admin? || manager? || ConsultantNetworkAccess.can_edit_opportunity?(user, record)
  def destroy?          = admin?

  def move_stage?         = update?
  # Lote: cada oportunidad se valida además con move_stage? (consultor: solo propias).
  def bulk_move_stage?    = admin? || manager? || consultant?
  def assign?             = manager_or_admin?
  def merge?              = manager_or_admin?
  def recalculate_bant?   = update?
  def kanban?             = staff?
  def export?             = manager_or_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      if admin? || manager? || viewer?
        scope.all
      elsif consultant?
        scope.where(owner_user_id: ConsultantNetworkAccess.visible_owner_ids(user, ActsAsTenant.current_tenant))
      else
        scope.none
      end
    end
  end

  private

  def owner?
    ConsultantNetworkAccess.can_edit_opportunity?(user, record)
  end
end
