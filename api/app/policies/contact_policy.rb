# frozen_string_literal: true

# ============================================================================
# ContactPolicy
# ============================================================================
# - admin/manager: ven y editan todos los contactos del tenant.
# - consultant: contactos propios, vinculados a sus oportunidades, o SIN DUEÑO
#   (leads nuevos que escriben por WhatsApp antes de ser calificados — bandeja
#   "sin asignar" del inbox, compartida entre todos los consultores del tenant
#   para poder reclamarlos).
# - viewer: solo lectura sobre todos.
# ============================================================================
class ContactPolicy < ApplicationPolicy
  def index?            = staff?
  def show?             = staff? && (manager_or_admin? || viewer? || contact_owner? || unassigned?)
  def create?           = admin? || manager? || consultant?
  def update?           = admin? || manager? || contact_owner?
  def destroy?          = admin?
  def bulk_destroy?     = admin?
  # Marcar opt-in manual de WhatsApp (consentimiento verificado fuera del sistema,
  # ej. cliente existente, contacto que dio permiso presencial/telefónico).
  def bulk_whatsapp_opt_in? = manager_or_admin?
  def check_duplicates? = admin? || manager? || consultant?
  def export?           = manager_or_admin?
  # Reclamar un contacto sin dueño (botón "Tomar lead" en el inbox).
  def claim?             = (admin? || manager? || consultant?) && record.owner_user_id.nil?
  # Responder por WhatsApp desde el inbox sin abrir una oportunidad: dueño del
  # contacto, o cualquier consultor si todavía no tiene dueño (sin_asignar).
  def reply_whatsapp?    = admin? || manager? || (consultant? && (contact_owner? || unassigned?))

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      if admin? || manager? || viewer?
        scope.all
      elsif consultant?
        opp_contact_ids = Opportunity.where(owner_user_id: user.id).where.not(contact_id: nil).select(:contact_id).distinct
        scope.where(owner_user_id: user.id)
             .or(scope.where(id: opp_contact_ids))
             .or(scope.where(owner_user_id: nil))
      else
        scope.none
      end
    end
  end

  private

  def contact_owner?
    record.owner_user_id == user&.id ||
      record.opportunities.where(owner_user_id: user&.id).exists?
  end

  def unassigned?
    consultant? && record.owner_user_id.nil?
  end
end
