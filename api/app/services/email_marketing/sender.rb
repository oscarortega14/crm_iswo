# frozen_string_literal: true

module EmailMarketing
  # ==========================================================================
  # EmailMarketing::Sender — remitente de campañas de correo de un tenant
  # ==========================================================================
  # Cada empresa envía desde su propio dominio (ej. info@iswo.com.co), que se
  # verifica en AWS SES con Easy DKIM. Se guarda en tenant.settings["email_marketing"]:
  #
  #   domain, from_local, from_name, reply_to, address  → los edita el admin
  #   status, dkim_tokens, verified_at, checked_at      → los escribe este servicio
  #
  # status: not_started | pending | verified | failed (estado DKIM en SES).
  # ==========================================================================
  class Sender
    EDITABLE = %w[domain from_local from_name reply_to address].freeze
    DOMAIN_FORMAT = /\A(?=.{4,253}\z)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

    attr_reader :tenant

    def initialize(tenant)
      @tenant = tenant
    end

    def config
      (tenant.settings || {})["email_marketing"] || {}
    end

    def domain     = config["domain"].to_s
    def from_local = config["from_local"].presence || "info"
    def from_name  = config["from_name"].presence || tenant.name
    def reply_to   = config["reply_to"].presence
    def address    = config["address"].presence
    def status     = config["status"].presence || "not_started"
    def verified?  = status == "verified" && domain.present?

    def from_email
      "#{from_local}@#{domain}"
    end

    def from_header
      name = from_name.to_s.delete('"<>')
      %("#{name}" <#{from_email}>)
    end

    # Registros DNS que el admin debe crear en su proveedor de dominio.
    def dns_records
      return [] if domain.blank?

      dkim = Array(config["dkim_tokens"]).map do |token|
        { "type" => "CNAME", "name" => "#{token}._domainkey.#{domain}",
          "value" => "#{token}.dkim.amazonses.com", "purpose" => "dkim" }
      end
      dkim + [ { "type" => "TXT", "name" => "_dmarc.#{domain}", "value" => "v=DMARC1; p=none;",
                 "purpose" => "dmarc" } ]
    end

    # Guarda los datos editables. Si cambia el dominio, se reinicia la verificación.
    def update!(attrs)
      attrs = attrs.to_h.stringify_keys.slice(*EDITABLE).transform_values { |v| v.to_s.strip }
      attrs["domain"] = attrs["domain"].downcase.delete_prefix("@") if attrs.key?("domain")
      attrs["from_local"] = attrs["from_local"].downcase if attrs.key?("from_local")
      validate!(attrs)

      next_config = config.merge(attrs)
      if attrs.key?("domain") && attrs["domain"] != domain
        next_config = next_config.except("status", "dkim_tokens", "verified_at", "checked_at")
      end
      save_config!(next_config)
    end

    # Crea la identidad del dominio en SES (o la consulta si ya existe) y
    # guarda los tokens DKIM para mostrar los registros DNS.
    def start_verification!
      raise ArgumentError, "Configura primero el dominio." if domain.blank?

      begin
        resp = Ses.client.create_email_identity(email_identity: domain)
        apply_identity!(resp.dkim_attributes, resp.verified_for_sending_status)
      rescue Aws::SESV2::Errors::AlreadyExistsException
        refresh!
      end
    end

    # Consulta el estado de verificación en SES.
    def refresh!
      raise ArgumentError, "Configura primero el dominio." if domain.blank?

      resp = Ses.client.get_email_identity(email_identity: domain)
      apply_identity!(resp.dkim_attributes, resp.verified_for_sending_status)
    rescue Aws::SESV2::Errors::NotFoundException
      save_config!(config.merge("status" => "not_started", "dkim_tokens" => [], "checked_at" => Time.current.iso8601))
    end

    def as_json(*)
      {
        "domain" => domain.presence, "from_local" => from_local, "from_name" => from_name,
        "from_email" => domain.present? ? from_email : nil, "reply_to" => reply_to, "address" => address,
        "status" => status, "verified_at" => config["verified_at"], "checked_at" => config["checked_at"],
        "dns_records" => dns_records, "tracking_enabled" => Ses.configuration_set.present?
      }
    end

    private

    def apply_identity!(dkim, verified_for_sending)
      dkim_status = dkim&.status.to_s.upcase
      status =
        if verified_for_sending && dkim_status == "SUCCESS" then "verified"
        elsif %w[FAILED TEMPORARY_FAILURE].include?(dkim_status) then "failed"
        else "pending"
        end
      next_config = config.merge(
        "status" => status, "dkim_tokens" => Array(dkim&.tokens), "checked_at" => Time.current.iso8601
      )
      next_config["verified_at"] ||= Time.current.iso8601 if status == "verified"
      save_config!(next_config)
    end

    def validate!(attrs)
      if attrs["domain"].present? && !attrs["domain"].match?(DOMAIN_FORMAT)
        raise ArgumentError, "El dominio no es válido (ej. iswo.com.co)."
      end
      if attrs["from_local"].present? && !attrs["from_local"].match?(/\A[a-z0-9][a-z0-9._+-]{0,63}\z/)
        raise ArgumentError, "La parte antes de la @ no es válida (ej. info)."
      end
      return if attrs["reply_to"].blank? || attrs["reply_to"].match?(URI::MailTo::EMAIL_REGEXP)

      raise ArgumentError, "El correo de respuesta no es válido."
    end

    def save_config!(next_config)
      tenant.update!(settings: (tenant.settings || {}).merge("email_marketing" => next_config))
    end
  end
end
