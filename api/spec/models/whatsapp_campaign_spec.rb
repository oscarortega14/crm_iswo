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

    it "falla si la plantilla no está aprobada en Meta (PENDING/REJECTED/PAUSED)" do
      campaign.save!
      %w[PENDING REJECTED PAUSED].each do |meta|
        template.update!(meta_status: meta)
        expect { campaign.launch! }.to raise_error(ArgumentError, /#{meta} en Meta/)
      end
      expect(campaign.reload).to be_status_draft
    end

    it "falla si la plantilla está desactivada en el catálogo" do
      campaign.save!
      template.update!(active: false)
      expect { campaign.launch! }.to raise_error(ArgumentError, /desactivada/)
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

    it "con una plantilla opt_in_request, deja pending incluso a contactos sin opt-in" do
      opt_in_template = create(:whatsapp_template, :opt_in_request, tenant: tenant, variable_labels: ["Nombre"])
      campaign.whatsapp_template = opt_in_template
      no_opt_in = create(:contact, tenant: tenant)
      opp = create(:opportunity, tenant: tenant, contact: no_opt_in, pipeline: pipeline,
                    pipeline_stage: pipeline.pipeline_stages.first)

      campaign.save!
      campaign.launch!

      recipient = campaign.whatsapp_campaign_recipients.find_by(contact_id: opp.contact_id)
      expect(recipient.status).to eq("pending")
      expect(campaign.skipped_no_opt_in_count).to eq(0)
    end

    it "con una plantilla opt_in_request, igual excluye a quien dijo que no (opt-out)" do
      opt_in_template = create(:whatsapp_template, :opt_in_request, tenant: tenant, variable_labels: ["Nombre"])
      campaign.whatsapp_template = opt_in_template
      said_no = create(:contact, tenant: tenant)
      said_no.mark_whatsapp_opt_out!(source: "reply")
      create(:opportunity, tenant: tenant, contact: said_no, pipeline: pipeline,
                           pipeline_stage: pipeline.pipeline_stages.first)

      campaign.save!
      campaign.launch!

      recipient = campaign.whatsapp_campaign_recipients.find_by(contact_id: said_no.id)
      expect(recipient.status).to eq("skipped_no_opt_in")
      expect(recipient.skip_reason).to eq("no autorizó WhatsApp (opt-out)")
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

  describe "#duplicate!" do
    let(:user) { create(:user, :admin, tenant: tenant) }

    it "crea un borrador con la misma plantilla, variables y audiencia" do
      campaign.audience_filters = { "temperature" => "hot" }
      campaign.save!
      campaign.update!(status: "completed")

      copy = campaign.duplicate!(user)

      expect(copy).to be_persisted
      expect(copy).to be_status_draft
      expect(copy).to have_attributes(
        name: "#{campaign.name} (copia)", whatsapp_template_id: template.id,
        variable_field_map: [ "contact.first_name" ], audience_filters: { "temperature" => "hot" },
        created_by_user_id: user.id
      )
    end

    it "deja el mapeo vacío si la plantilla cambió de número de variables" do
      campaign.save!
      template.update!(variable_labels: %w[Nombre Empresa])
      copy = campaign.duplicate!(user)
      expect(copy.variable_field_map).to eq([ "", "" ])
    end
  end

  describe "#delivery_stats (resultado real según Meta)" do
    it "cuenta pendientes, aceptados, entregados, leídos, fallidos y omitidos" do
      campaign.save!
      contact = -> { create(:contact, tenant: tenant) }
      msg = ->(status) { create(:whatsapp_message, :outbound, :cloud, tenant: tenant, status: status) }
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact.call, status: "pending")
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact.call,
                                           status: "sent", whatsapp_message: msg.call("sent"))
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact.call,
                                           status: "sent", whatsapp_message: msg.call("delivered"))
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact.call,
                                           status: "sent", whatsapp_message: msg.call("read"))
      # «enviado» en el CRM pero Meta lo rechazó (p. ej. plantilla no aprobada)
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact.call,
                                           status: "sent", whatsapp_message: msg.call("failed"))
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact.call,
                                           status: "skipped_no_opt_in")

      expect(campaign.delivery_stats).to eq(
        "total" => 6, "pending" => 1, "sent" => 1, "delivered" => 1, "read" => 1, "failed" => 1, "skipped" => 1
      )
    end
  end
end
