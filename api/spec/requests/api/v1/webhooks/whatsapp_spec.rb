# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Webhooks::Whatsapp", type: :request do
  around do |example|
    originals = ENV.to_h.slice("META_APP_SECRET", "WHATSAPP_CLOUD_VERIFY_TOKEN")
    example.run
  ensure
    %w[META_APP_SECRET WHATSAPP_CLOUD_VERIFY_TOKEN].each do |k|
      originals.key?(k) ? (ENV[k] = originals[k]) : ENV.delete(k)
    end
  end

  describe "GET /api/v1/webhooks/whatsapp/cloud (verify)" do
    it "devuelve hub.challenge si el token coincide" do
      ENV["WHATSAPP_CLOUD_VERIFY_TOKEN"] = "cloud-token"
      get "/api/v1/webhooks/whatsapp/cloud", params: {
        "hub.verify_token" => "cloud-token",
        "hub.challenge"    => "42"
      }
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("42")
    end

    it "403 si el token no coincide" do
      ENV["WHATSAPP_CLOUD_VERIFY_TOKEN"] = "cloud-token"
      get "/api/v1/webhooks/whatsapp/cloud", params: {
        "hub.verify_token" => "nope", "hub.challenge" => "x"
      }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/webhooks/whatsapp/cloud" do
    let(:payload) do
      { object: "whatsapp_business_account", entry: [{ id: "WABA_ID", changes: [] }] }
    end

    it "procesa WebhookProcessorJob inline con 'whatsapp_cloud' sin secret (dev)" do
      ENV.delete("META_APP_SECRET")
      expect(WebhookProcessorJob).to receive(:perform_now).with(
        "whatsapp_cloud",
        hash_including("object" => "whatsapp_business_account", "received_at" => kind_of(String))
      )

      post "/api/v1/webhooks/whatsapp/cloud",
           params: payload.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
    end

    context "con META_APP_SECRET" do
      let(:secret) { "cloud-app-secret" }
      let(:raw)    { payload.to_json }
      let(:sig)    { "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, raw) }
      before { ENV["META_APP_SECRET"] = secret }

      it "acepta con firma válida" do
        expect(WebhookProcessorJob).to receive(:perform_now)
        post "/api/v1/webhooks/whatsapp/cloud",
             params: raw,
             headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => sig }
        expect(response).to have_http_status(:ok)
      end

      it "rechaza con firma inválida (403)" do
        expect(WebhookProcessorJob).not_to receive(:perform_now)
        post "/api/v1/webhooks/whatsapp/cloud",
             params: raw,
             headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => "sha256=bad" }
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "400 si el body no es JSON válido" do
      ENV.delete("META_APP_SECRET")
      post "/api/v1/webhooks/whatsapp/cloud",
           params: "not-json",
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end
  end
end
