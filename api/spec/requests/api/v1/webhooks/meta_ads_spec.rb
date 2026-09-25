# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Webhooks::MetaAds", type: :request do
  around do |example|
    original = ENV.to_h.slice("META_VERIFY_TOKEN", "META_APP_SECRET")
    example.run
  ensure
    ENV["META_VERIFY_TOKEN"] = original["META_VERIFY_TOKEN"]
    ENV["META_APP_SECRET"]   = original["META_APP_SECRET"]
    ENV.delete("META_VERIFY_TOKEN") if original["META_VERIFY_TOKEN"].nil?
    ENV.delete("META_APP_SECRET")   if original["META_APP_SECRET"].nil?
  end

  describe "GET /api/v1/webhooks/meta (hub verify)" do
    it "devuelve hub.challenge en plano si el token coincide" do
      ENV["META_VERIFY_TOKEN"] = "secret-verify"

      get "/api/v1/webhooks/meta", params: {
        "hub.mode"         => "subscribe",
        "hub.challenge"    => "challenge-123",
        "hub.verify_token" => "secret-verify"
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("challenge-123")
    end

    it "403 si el token no coincide" do
      ENV["META_VERIFY_TOKEN"] = "right"
      get "/api/v1/webhooks/meta", params: { "hub.verify_token" => "wrong", "hub.challenge" => "x" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/webhooks/meta" do
    # Sin firma por default: api/.env (dotenv) puede traer META_APP_SECRET real.
    before { ENV.delete("META_APP_SECRET") }

    let(:payload) do
      {
        entry: [
          {
            id: "PAGE_ID_123",
            changes: [
              { value: { "leadgen_id" => "LEAD_ID_ABC" } }
            ]
          }
        ]
      }
    end

    it "encola WebhookProcessorJob por cada change con leadgen_id" do
      expect(WebhookProcessorJob).to receive(:perform_later).with(
        "meta",
        hash_including("leadgen_id" => "LEAD_ID_ABC", "page_id" => "PAGE_ID_123", "received_at" => kind_of(String))
      )

      post "/api/v1/webhooks/meta",
           params: payload.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
    end

    it "ignora changes sin leadgen_id (no encola)" do
      expect(WebhookProcessorJob).not_to receive(:perform_later)

      post "/api/v1/webhooks/meta",
           params: { entry: [{ id: "P1", changes: [{ value: {} }] }] }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
    end

    it "400 si el body no es JSON válido" do
      post "/api/v1/webhooks/meta",
           params: "not-json",
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end

    context "con META_APP_SECRET configurado" do
      let(:secret) { "super-secret-app-token" }
      let(:raw_body) { payload.to_json }
      let(:valid_signature) do
        "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
      end

      before { ENV["META_APP_SECRET"] = secret }

      it "acepta con firma válida (X-Hub-Signature-256)" do
        expect(WebhookProcessorJob).to receive(:perform_later)

        post "/api/v1/webhooks/meta",
             params: raw_body,
             headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => valid_signature }

        expect(response).to have_http_status(:ok)
      end

      it "rechaza con firma inválida (403)" do
        expect(WebhookProcessorJob).not_to receive(:perform_later)

        post "/api/v1/webhooks/meta",
             params: raw_body,
             headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => "sha256=wrong" }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
