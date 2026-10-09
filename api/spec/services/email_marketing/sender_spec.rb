# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailMarketing::Sender do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:sender) { described_class.new(tenant) }

  it "sin configurar: no verificado y remitente por defecto con el nombre del tenant" do
    expect(sender.verified?).to be(false)
    expect(sender.status).to eq("not_started")
    expect(sender.from_name).to eq(tenant.name)
  end

  describe "#update!" do
    it "normaliza y guarda el dominio y el remitente" do
      sender.update!(domain: " @ISWO.com.co ", from_local: "Info", from_name: "ISWO", reply_to: "ventas@iswo.com.co")
      fresh = described_class.new(tenant.reload)
      expect(fresh.from_email).to eq("info@iswo.com.co")
      expect(fresh.from_header).to eq('"ISWO" <info@iswo.com.co>')
      expect(fresh.reply_to).to eq("ventas@iswo.com.co")
    end

    it "rechaza dominios o correos inválidos" do
      expect { sender.update!(domain: "no es dominio") }.to raise_error(ArgumentError, /dominio/)
      expect { sender.update!(reply_to: "x@") }.to raise_error(ArgumentError, /respuesta/)
    end

    it "cambiar el dominio reinicia la verificación" do
      verify_email_sender!(tenant)
      sender.update!(domain: "otro.com")
      expect(described_class.new(tenant.reload)).to have_attributes(status: "not_started", verified?: false)
    end
  end

  describe "verificación en SES" do
    before { sender.update!(domain: "iswo.com.co") }

    it "crea la identidad y expone los registros DKIM y DMARC" do
      ses_client.stub_responses(:create_email_identity, {
        identity_type: "DOMAIN", verified_for_sending_status: false,
        dkim_attributes: { status: "PENDING", tokens: %w[tok1 tok2 tok3] }
      })
      sender.start_verification!

      fresh = described_class.new(tenant.reload)
      expect(fresh.status).to eq("pending")
      expect(ses_requests(:create_email_identity).first[:params]).to eq(email_identity: "iswo.com.co")
      expect(fresh.dns_records.first).to include("type" => "CNAME", "name" => "tok1._domainkey.iswo.com.co",
                                                 "value" => "tok1.dkim.amazonses.com")
      expect(fresh.dns_records.last).to include("type" => "TXT", "name" => "_dmarc.iswo.com.co")
    end

    it "si ya existía, consulta el estado; verificado cuando DKIM está OK" do
      ses_client.stub_responses(:create_email_identity, "AlreadyExistsException")
      ses_client.stub_responses(:get_email_identity, {
        verified_for_sending_status: true, dkim_attributes: { status: "SUCCESS", tokens: %w[tok1] }
      })
      sender.start_verification!
      expect(described_class.new(tenant.reload)).to have_attributes(status: "verified", verified?: true)
    end
  end
end
