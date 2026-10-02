# frozen_string_literal: true

# ============================================================================
# WhatsappTemplate — catálogo de plantillas aprobadas por Meta, por tenant
# ============================================================================
# Fuera de la ventana de servicio de 24h, WhatsApp exige una plantilla
# pre-aprobada para iniciar conversación (error 131047 en texto libre). Este
# catálogo evita que un consultor escriba a mano un `meta_template_name` con
# typos que Meta rechazaría.
#
# `opt_in_request`: marca a mano, una vez, sobre una plantilla aprobada por
# Meta específicamente redactada para pedir autorización de contacto. Una
# campaña que use una plantilla así marcada salta el gate de opt-in (ver
# WhatsappCampaign#launch! y WhatsappCampaigns::Dispatcher) — es la única
# forma de contactar a alguien sin opt-in todavía, y solo para pedírselo.
#
# `category`/`meta_status`/`meta_template_id`/`meta_synced_at`: solo los
# escribe WhatsApp::TemplateSync (botón "Sincronizar" en /whatsapp →
# Plantillas) — reflejan el estado real en Meta para detectar cambios
# hechos directo ahí (categoría, aprobación) sin pasar por el CRM.
# ============================================================================
class WhatsappTemplate < ApplicationRecord
  include TenantScoped

  belongs_to :tenant

  validates :name, :meta_template_name, :language, presence: true
  validates :meta_template_name,
            uniqueness: { scope: %i[tenant_id language], case_sensitive: false }

  scope :active, -> { where(active: true) }

  def variable_count
    Array(variable_labels).size
  end

  # true si Meta exige parámetros con nombre (`{{primer_nombre}}`) para esta
  # plantilla en vez del formato posicional clásico (`{{1}}`).
  def named_parameters?
    Array(variable_names).any?(&:present?)
  end
end
