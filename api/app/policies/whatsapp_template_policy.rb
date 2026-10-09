# frozen_string_literal: true

# ============================================================================
# WhatsappTemplatePolicy — catálogo de plantillas aprobadas por Meta.
# ============================================================================
class WhatsappTemplatePolicy < ApplicationPolicy
  def index?   = staff?
  def show?    = staff?
  def create?  = manager_or_admin?
  def update?  = manager_or_admin?
  def destroy? = admin?
  def sync?    = manager_or_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.all
  end
end
