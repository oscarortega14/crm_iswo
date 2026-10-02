# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ads::ConnectionTester do
  let(:tenant) { ActsAsTenant.current_tenant }

  describe "#call" do
    context "provider meta" do
      let(:integration) do
        build(:ad_integration, :meta, tenant: tenant, credentials: { "access_token" => "tok" })
      end

      it "devuelve true si Graph responde 200 con id" do
        stub_request(:get, %r{graph\.facebook\.com/v18\.0/me})
          .with(query: hash_including("access_token" => "tok"))
          .to_return(status: 200, body: { id: "1234" }.to_json,
                     headers: { "Content-Type" => "application/json" })

        expect(described_class.new(integration).call).to be(true)
      end

      it "devuelve false si Graph responde 401" do
        stub_request(:get, %r{graph\.facebook\.com/v18\.0/me})
          .to_return(status: 401, body: { error: { message: "bad token" } }.to_json,
                     headers: { "Content-Type" => "application/json" })

        expect(described_class.new(integration).call).to be(false)
      end

      it "devuelve false sin access_token configurado" do
        integration = build(:ad_integration, :meta, tenant: tenant, credentials: {})
        expect(described_class.new(integration).call).to be(false)
      end
    end

    context "provider google" do
      let(:integration) do
        build(:ad_integration, :google, tenant: tenant, credentials: { "refresh_token" => "rt" })
      end

      around do |ex|
        old_id  = ENV.fetch("GOOGLE_ADS_CLIENT_ID", nil)
        old_sec = ENV.fetch("GOOGLE_ADS_CLIENT_SECRET", nil)
        ENV["GOOGLE_ADS_CLIENT_ID"]     = "test-oauth-client-id"
        ENV["GOOGLE_ADS_CLIENT_SECRET"] = "test-oauth-client-secret"
        ex.run
        if old_id
          ENV["GOOGLE_ADS_CLIENT_ID"] = old_id
        else
          ENV.delete("GOOGLE_ADS_CLIENT_ID")
        end
        if old_sec
          ENV["GOOGLE_ADS_CLIENT_SECRET"] = old_sec
        else
          ENV.delete("GOOGLE_ADS_CLIENT_SECRET")
        end
      end

      it "intercambia refresh_token por access_token y devuelve true cuando funciona" do
        stub_request(:post, "https://oauth2.googleapis.com/token")
          .to_return(status: 200, body: { access_token: "ya29.fake" }.to_json,
                     headers: { "Content-Type" => "application/json" })

        expect(described_class.new(integration).call).to be(true)
      end

      it "devuelve false si Google responde error" do
        stub_request(:post, "https://oauth2.googleapis.com/token")
          .to_return(status: 400, body: { error: "invalid_grant" }.to_json,
                     headers: { "Content-Type" => "application/json" })

        expect(described_class.new(integration).call).to be(false)
      end

      it "devuelve false si en el servidor faltan GOOGLE_ADS_CLIENT_ID / SECRET" do
        ENV.delete("GOOGLE_ADS_CLIENT_ID")
        ENV.delete("GOOGLE_ADS_CLIENT_SECRET")
        result = described_class.new(integration).test
        expect(result.success?).to be(false)
        expect(result.message).to include("GOOGLE_ADS_CLIENT_ID")
      end
    end

    context "provider whatsapp_cloud" do
      let(:integration) do
        create(:ad_integration, :cloud, tenant: tenant,
               credentials: { "access_token" => "EAAGgoodtoken" })
      end

      around do |example|
        prev = ENV["WHATSAPP_CLOUD_API_VERSION"]
        ENV.delete("WHATSAPP_CLOUD_API_VERSION")
        example.run
      ensure
        prev ? (ENV["WHATSAPP_CLOUD_API_VERSION"] = prev) : ENV.delete("WHATSAPP_CLOUD_API_VERSION")
      end

      it "devuelve true si Graph GET /me responde con id" do
        stub_request(:get, %r{graph\.facebook\.com/v[\d.]+/me})
          .with(query: hash_including("access_token" => "EAAGgoodtoken"))
          .to_return(status: 200, body: { id: "999" }.to_json,
                     headers: { "Content-Type" => "application/json" })

        expect(described_class.new(integration).call).to be(true)
      end

      it "devuelve false con orientación si Meta devuelve código 190" do
        stub_request(:get, %r{graph\.facebook\.com/v[\d.]+/me})
          .to_return(
            status: 400,
            body: {
              error: {
                message: "Invalid OAuth access token - Cannot parse access token",
                type: "OAuthException",
                code: 190
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = described_class.new(integration).test
        expect(result.success?).to be(false)
        expect(result.message).to include("190").and include("Usuarios del sistema")
      end

      it "devuelve false si falta access_token" do
        empty = create(:ad_integration, :cloud, tenant: tenant, credentials: { "note" => "x" })
        result = described_class.new(empty).test
        expect(result.success?).to be(false)
        expect(result.message).to include("access_token")
      end
    end
  end
end
