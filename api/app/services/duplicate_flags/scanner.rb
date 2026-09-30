# frozen_string_literal: true

module DuplicateFlags
  # ==========================================================================
  # DuplicateFlags::Scanner — busca oportunidades abiertas duplicadas en un
  # tenant y crea las alertas (DuplicateFlag) que falten.
  # ==========================================================================
  # Grupos de posibles duplicados (solo contactos activos):
  #   1. Un mismo contacto con más de una oportunidad abierta.
  #   2. Contactos distintos con el mismo celular (blind index del E.164).
  #   3. Contactos distintos con el mismo correo (sin distinguir mayúsculas).
  #
  # Dentro de cada grupo se compara cada par de oportunidades abiertas: la más
  # reciente queda como `opportunity` (la duplicada) y la más antigua como
  # `duplicate_of_opportunity` (la existente, que gana al fusionar). No se
  # recrea una alerta para un par que ya tuvo una (pendiente o resuelta).
  #
  # Lo usan POST /duplicate_flags/scan y RefreshDuplicateCacheJob (diario).
  # Sin notificaciones: un escaneo masivo inundaría la campana; la pantalla
  # Duplicados y su contador muestran las alertas nuevas.
  # ==========================================================================
  class Scanner
    Result = Struct.new(:scanned, :created, keyword_init: true)

    def self.call(tenant:, actor:)
      new(tenant: tenant, actor: actor).call
    end

    def initialize(tenant:, actor:)
      @tenant = tenant
      @actor  = actor
    end

    def call
      groups  = contact_groups
      created = groups.sum { |contact_ids| flag_group(contact_ids) }
      Result.new(scanned: groups.size, created: created)
    end

    private

    def contacts
      @tenant.contacts.kept
    end

    def open_opportunities
      @tenant.opportunities.kept.open
    end

    def contact_groups
      same_contact = open_opportunities.group(:contact_id).having("COUNT(*) > 1").pluck(:contact_id).map { [ it ] }
      by_phone = contacts.where.not(phone_e164_bidx: nil)
                         .group(:phone_e164_bidx).having("COUNT(*) > 1")
                         .pluck(Arel.sql("ARRAY_AGG(contacts.id)"))
      by_email = contacts.where.not(email: [ nil, "" ])
                         .group(Arel.sql("LOWER(contacts.email)")).having("COUNT(*) > 1")
                         .pluck(Arel.sql("ARRAY_AGG(contacts.id)"))
      (same_contact + by_phone + by_email).map(&:sort).uniq
    end

    def flag_group(contact_ids)
      opps = open_opportunities.where(contact_id: contact_ids).includes(:contact).order(:created_at, :id).to_a
      opps.combination(2).count { |older, newer| create_flag(newer, older) }
    end

    def create_flag(newer, older)
      pair = DuplicateFlag.where(tenant_id: @tenant.id)
      return false if pair.exists?(opportunity_id: newer.id, duplicate_of_opportunity_id: older.id)
      return false if pair.exists?(opportunity_id: older.id, duplicate_of_opportunity_id: newer.id)

      DuplicateFlag.create!(
        tenant:                   @tenant,
        opportunity:              newer,
        duplicate_of_opportunity: older,
        detected_by_user:         @actor,
        matched_on:               matched_on(newer.contact, older.contact),
        match_score:              1.0
      )
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("[DuplicateFlags::Scanner] #{newer.id} vs #{older.id}: #{e.message}")
      false
    end

    def matched_on(a, b)
      same_phone = a.phone_e164_bidx.present? && a.phone_e164_bidx == b.phone_e164_bidx
      same_email = a.email.present? && a.email.to_s.casecmp?(b.email.to_s)
      return "both" if same_phone && same_email
      return "email" if same_email && !same_phone
      return "phone" if same_phone

      # Mismo contacto sin celular ni correo coincidentes: se usa lo que tenga.
      a.phone_e164_bidx.present? ? "phone" : "email"
    end
  end
end
