# frozen_string_literal: true

module Contacts
  # ==========================================================================
  # Contacts::DocumentId — interpreta una columna «Cédula o NIT» (Colombia) y
  # decide si el contacto es persona natural o empresa.
  # ==========================================================================
  # Empresa (NIT):  «NIT 900123456», «900.123.456-7» (con dígito de
  #                 verificación) o 9 dígitos que empiezan por 8 o 9 (rango de
  #                 NIT de personas jurídicas).
  # Persona (CC):   «CC 1020304050», «C.C. 79.123.456» o cualquier otro número
  #                 (cédulas de 6-8 dígitos antiguas y de 10 dígitos nuevas).
  # ==========================================================================
  module DocumentId
    Result = Struct.new(:number, :kind, keyword_init: true)

    COMPANY_PREFIX = /\A(NIT)\b[\s.:#-]*/i
    PERSON_PREFIX  = /\A(C\.?\s?C\.?|C[ÉE]DULA|CE)\b[\s.:#-]*/i

    module_function

    # @return [Result, nil] número limpio («900123456-7», «1020304050») y kind
    def classify(raw)
      text = raw.to_s.strip
      return nil if text.blank?

      explicit =
        if text.match?(COMPANY_PREFIX) then "company"
        elsif text.match?(PERSON_PREFIX) then "person"
        end
      body = text.sub(COMPANY_PREFIX, "").sub(PERSON_PREFIX, "")
      digits, dv = body.gsub(/[\s.,]/, "").split("-", 2)
      digits = digits.to_s.gsub(/\D/, "")
      dv = dv.to_s.gsub(/\D/, "").presence
      return nil if digits.blank?

      kind = explicit || (dv || nit_range?(digits) ? "company" : "person")
      Result.new(number: dv && kind == "company" ? "#{digits}-#{dv}" : digits, kind: kind)
    end

    def nit_range?(digits)
      digits.length == 9 && digits.start_with?("8", "9")
    end
  end
end
