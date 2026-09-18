# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappCampaign, type: :model do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:template) { create(:whatsapp_template, tenant: tenant, variable_labels: ["Nombre"]) }

  subject(:campaign) { build(:whatsapp_campaign, tenant: tenant, whatsapp_template: template, variable_field_map: ["contact.first_name"]) }

  describe "validaciones" do
    it { is_expected.to be_valid }

    it "requiere name" do
      campaign.name = nil
      expect(campaign).not_to be_valid
    end

    it "requiere batch_size positivo" do
      campaign.batch_size = 0
      expect(campaign).not_to be_valid
    end

    it "requiere batch_interval_minutes >= 1" do
      campaign.batch_interval_minutes = 0
      expect(campaign).not_to be_valid
    end

    it "variable_field_map debe tener el mismo tamaño que las variables de la plantilla" do
      campaign.variable_field_map = []
      expect(campaign).not_to be_valid
      expect(campaign.errors[:variable_field_map]).to be_present
    end

    it "acepta plantilla sin variables con variable_field_map vacío" do
      no_var_template = create(:whatsapp_template, tenant: tenant, variable_labels: [])
      campaign.whatsapp_template = no_var_template
      campaign.variable_field_map = []
      expect(campaign).to be_valid
    end
  end

  describe "#launch!" do
    let!(:integration) do
      create(:ad_integration, :cloud, tenant: tenant, account_identifier: "123456")
    end
    let(:pipeline) { create(:pipeline_with_stages, tenant: tenant) }

    it "falla si no está en borrador" do
      campaign.save!
      campaign.update!(status: "running")
      expect { campaign.launch! }.to raise_error(ArgumentError, /borrador/)
    end

    it "falla si no hay WhatsApp Cloud configurado" do
      integration.destroy!
      campaign.save!
      expect { campaign.launch! }.to raise_error(ArgumentError, /Ajustes → Integraciones/)
    end

    it "crea recipients pending para contactos con opt-in, y skipped_no_opt_in para los que no" do
      opted_in = create(:contact, tenant: tenant, whatsapp_opt_in_at: Time.current)
      opted_out = create(:contact, tenant: tenant)
      opp1 = create(:opportunity, tenant: tenant, contact: opted_in, pipeline: pipeline,
                     pipeline_stage: pipeline.pipeline_stages.first)
      opp2 = create(:opportunity, tenant: tenant, contact: opted_out, pipeline: pipeline,
                     pipeline_stage: pipeline.pipeline_stages.first)

      campaign.save!
      campaign.launch!

      recipients = campaign.whatsapp_campaign_recipients.index_by(&:contact_id)
      expect(recipients[opp1.contact_id].status).to eq("pending")
      expect(recipients[opp2.contact_id].status).to eq("skipped_no_opt_in")
      expect(campaign.reload.status).to eq("running")
      expect(campaign.total_recipients).to eq(2)
      expect(campaign.skipped_no_opt_in_count).to eq(1)
    end
  end

  describe "#pause! / #resume! / #cancel!" do
    it "pausa y reanuda" do
      campaign.save!
      campaign.update!(status: "running")
      campaign.pause!
      expect(campaign.reload.status).to eq("paused")
      campaign.resume!
      expect(campaign.reload.status).to eq("running")
    end

    it "cancela y marca pending como skipped_no_opt_in con motivo" do
      campaign.save!
      campaign.update!(status: "running")
      recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, status: "pending")

      campaign.cancel!

      expect(campaign.reload.status).to eq("canceled")
      expect(recipient.reload.status).to eq("skipped_no_opt_in")
      expect(recipient.skip_reason).to eq("campaña cancelada")
    end
  end
end
