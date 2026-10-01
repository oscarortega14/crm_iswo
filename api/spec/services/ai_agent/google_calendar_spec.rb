# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiAgent::GoogleCalendar do
  let(:key) { OpenSSL::PKey::RSA.new(2048) }
  let(:creds) do
    { "type" => "service_account", "client_email" => "crm@iswo-crm.iam.gserviceaccount.com",
      "private_key" => key.to_pem }
  end

  around do |example|
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = creds.to_json
    Rails.cache.clear
    example.run
  ensure
    ENV.delete("GOOGLE_SERVICE_ACCOUNT_JSON")
  end

  before do
    stub_request(:post, described_class::TOKEN_URL)
      .with { |req| URI.decode_www_form(req.body).to_h["grant_type"].include?("jwt-bearer") }
      .to_return(status: 200, body: { access_token: "ya29.token", expires_in: 3600 }.to_json)
  end

  it "expone el correo de la cuenta de servicio (también desde base64)" do
    expect(described_class.service_account_email).to eq("crm@iswo-crm.iam.gserviceaccount.com")
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = Base64.strict_encode64(creds.to_json)
    expect(described_class.configured?).to be(true)
  end

  it "firma el JWT y consulta lo ocupado (freeBusy)" do
    stub = stub_request(:post, "#{described_class::API_BASE}/freeBusy")
           .with(headers: { "Authorization" => "Bearer ya29.token" })
           .to_return(status: 200, body: { calendars: { "agenda@iswo.com.co" => { busy: [
             { start: "2026-10-06T14:00:00Z", end: "2026-10-06T15:00:00Z" }
           ] } } }.to_json)

    busy = described_class.new("agenda@iswo.com.co").busy(Time.utc(2026, 10, 6), Time.utc(2026, 10, 7))
    expect(stub).to have_been_requested
    expect(busy).to eq([ [ Time.utc(2026, 10, 6, 14), Time.utc(2026, 10, 6, 15) ] ])
  end

  it "calendario no compartido → mensaje claro con el correo a compartir" do
    stub_request(:post, "#{described_class::API_BASE}/freeBusy")
      .to_return(status: 200, body: { calendars: { "x@y.com" => { errors: [ { reason: "notFound" } ] } } }.to_json)

    expect { described_class.new("x@y.com").busy(Time.current, 1.day.from_now) }
      .to raise_error(described_class::Error, /compartido con crm@iswo-crm/)
  end

  it "crea el evento sin enviar invitaciones y devuelve su id" do
    stub = stub_request(:post, "#{described_class::API_BASE}/calendars/agenda%40iswo.com.co/events?sendUpdates=none")
           .with { |req| JSON.parse(req.body)["summary"] == "Reunión ISWO – María" }
           .to_return(status: 200, body: { id: "evt123" }.to_json)

    id = described_class.new("agenda@iswo.com.co").create_event(
      summary: "Reunión ISWO – María", description: "x", starts_at: Time.current, ends_at: 1.hour.from_now,
      time_zone: "America/Bogota"
    )
    expect(id).to eq("evt123")
    expect(stub).to have_been_requested
  end

  it "sin cuenta de servicio no se puede usar" do
    ENV.delete("GOOGLE_SERVICE_ACCOUNT_JSON")
    expect { described_class.new("agenda@iswo.com.co") }.to raise_error(described_class::Error, /cuenta de servicio/)
  end
end
