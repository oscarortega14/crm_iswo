# frozen_string_literal: true

module Contacts
  # ==========================================================================
  # Contacts::Merger — une dos contactos duplicados en uno solo.
  # ==========================================================================
  # `survivor` se conserva (el existente); `absorbed` le entrega todo y queda
  # eliminado (soft-delete). Lo usa DuplicateFlagsController#merge cuando las
  # oportunidades fusionadas pertenecen a contactos distintos.
  #
  # - Datos: el sobreviviente conserva los suyos; solo se completan los vacíos
  #   (correo, celular, documento, empresa, cargo, ciudad, país, dueño). El
  #   nombre provisional de WhatsApp («Contacto 1234») se reemplaza por el real.
  # - Notas: se suman. Campos personalizados: gana el sobreviviente.
  # - WhatsApp: se conserva el opt-in más antiguo; un opt-out de cualquiera se
  #   respeta (privacidad).
  # - Orígenes: unión de los de ambos (landing, importación, WhatsApp, manual…).
  # - Se mueven oportunidades (incluidas las cerradas), mensajes de WhatsApp,
  #   formularios de landing, destinatarios de campañas (WhatsApp y correo) y
  #   notificaciones. Una baja de correos del absorbido se respeta.
  # ==========================================================================
  class Merger
    FILLABLE = %i[email phone_e164 document_id company_name job_title city country owner_user_id].freeze
    WHATSAPP_PLACEHOLDER = "Contacto"

    Result = Struct.new(:survivor, :absorbed, :moved, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(survivor:, absorbed:, performed_by: nil)
      raise ArgumentError, "no se puede fusionar un contacto consigo mismo" if survivor.id == absorbed.id
      raise ArgumentError, "los contactos deben ser del mismo tenant" if survivor.tenant_id != absorbed.tenant_id

      @survivor     = survivor
      @absorbed     = absorbed
      @performed_by = performed_by
    end

    def call
      moved = {}
      ActiveRecord::Base.transaction do
        merge_attributes!
        moved = move_records!
        @absorbed.discard
        audit!(moved)
      end
      Result.new(survivor: @survivor.reload, absorbed: @absorbed.reload, moved: moved)
    end

    private

    def merge_attributes!
      FILLABLE.each do |field|
        next if @survivor.public_send(field).present?

        value = @absorbed.public_send(field)
        @survivor.public_send("#{field}=", value) if value.present?
      end

      if placeholder_name?(@survivor) && !placeholder_name?(@absorbed)
        @survivor.first_name = @absorbed.first_name
        @survivor.last_name  = @absorbed.last_name
      end

      @survivor.notes = [ @survivor.notes, @absorbed.notes ].map(&:presence).compact.uniq.join("\n\n").presence
      @survivor.custom_fields = (@absorbed.custom_fields || {}).merge(@survivor.custom_fields || {})
      merge_whatsapp_consent!
      @survivor.origins = merged_origins
      @survivor.save!
    end

    # Nombre provisional que pone el webhook de WhatsApp a quien escribe sin
    # estar en el CRM («Contacto» + últimos dígitos).
    def placeholder_name?(contact)
      contact.first_name.blank? || (contact.first_name == WHATSAPP_PLACEHOLDER && contact.source_kind == "whatsapp")
    end

    def merge_whatsapp_consent!
      if @absorbed.whatsapp_opt_in_at.present? &&
         (@survivor.whatsapp_opt_in_at.blank? || @absorbed.whatsapp_opt_in_at < @survivor.whatsapp_opt_in_at)
        @survivor.whatsapp_opt_in_at     = @absorbed.whatsapp_opt_in_at
        @survivor.whatsapp_opt_in_source = @absorbed.whatsapp_opt_in_source
      end
      merge_email_opt_out!
      return unless @absorbed.respond_to?(:whatsapp_opt_out_at) && @absorbed.whatsapp_opt_out_at.present?

      @survivor.whatsapp_opt_out_at ||= @absorbed.whatsapp_opt_out_at
    end

    # Una baja de correos de cualquiera se respeta si comparten el mismo correo.
    def merge_email_opt_out!
      return if @absorbed.email_opt_out_at.blank? || @survivor.email_opt_out_at.present?
      return unless @survivor.email.blank? || @survivor.email.casecmp?(@absorbed.email.to_s)

      @survivor.email_opt_out_at     = @absorbed.email_opt_out_at
      @survivor.email_opt_out_source = @absorbed.email_opt_out_source
    end

    def merged_origins
      (Array(@survivor.origins) + Array(@absorbed.origins))
        .uniq { |o| [ o["kind"], o["label"].to_s ] }
        .sort_by { |o| o["at"].to_s }
    end

    def move_records!
      id_from = @absorbed.id
      id_to   = @survivor.id
      moved = {
        opportunities:            Opportunity.where(contact_id: id_from).update_all(contact_id: id_to),
        whatsapp_messages:        WhatsappMessage.where(contact_id: id_from).update_all(contact_id: id_to),
        email_recipients:         move_email_recipients!,
        landing_form_submissions: LandingFormSubmission.where(contact_id: id_from).update_all(contact_id: id_to),
        notifications:            Notification.where(resource_type: "Contact", resource_id: id_from)
                                              .update_all(resource_id: id_to)
      }
      moved[:campaign_recipients] = move_campaign_recipients!
      moved
    end

    # Un contacto solo puede estar una vez por campaña: si ambos estaban en la
    # misma, se conserva el registro del sobreviviente.
    def move_campaign_recipients!
      survivor_campaigns = WhatsappCampaignRecipient.where(contact_id: @survivor.id).pluck(:whatsapp_campaign_id)
      absorbed = WhatsappCampaignRecipient.where(contact_id: @absorbed.id)
      absorbed.where(whatsapp_campaign_id: survivor_campaigns).delete_all
      absorbed.update_all(contact_id: @survivor.id)
    end

    def move_email_recipients!
      survivor_campaigns = EmailCampaignRecipient.where(contact_id: @survivor.id).pluck(:email_campaign_id)
      absorbed = EmailCampaignRecipient.where(contact_id: @absorbed.id)
      absorbed.where(email_campaign_id: survivor_campaigns).delete_all
      absorbed.update_all(contact_id: @survivor.id)
    end

    def audit!(moved)
      AuditLogger.record!(
        tenant:      @survivor.tenant,
        user:        @performed_by,
        action:      "contact.merge",
        entity_type: "Contact",
        entity_id:   @survivor.id,
        metadata:    { absorbed_contact_id: @absorbed.id, moved: moved }
      )
    end
  end
end
