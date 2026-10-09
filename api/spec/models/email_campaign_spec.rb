# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailCampaign do
  let(:tenant) { ActsAsTenant.current_tenant }

  describe "#launch!" do
    it "no se lanza sin dominio verificado" do
      campaign = create(:email_campaign, tenant: tenant)
      expect { campaign.launch! }.to raise_error(ArgumentError, /verificar el dominio/)
    end

    context "con dominio verificado" do
      before { verify_email_sender!(tenant) }

      it "congela la audiencia: sin duplicados por correo y sin dados de baja ni eliminados" do
        a = create(:contact, tenant: tenant, email: "ana@example.com")
        create(:contact, tenant: tenant, email: "ANA@example.com", first_name: "Ana bis")
        create(:contact, tenant: tenant, email: "baja@example.com", email_opt_out_at: Time.current)
        create(:contact, tenant: tenant, email: nil)
        create(:contact, tenant: tenant, email: "borrado@example.com").discard

        campaign = create(:email_campaign, tenant: tenant)
        campaign.launch!

        expect(campaign.reload).to be_status_running
        expect(campaign.total_recipients).to eq(1)
        expect(campaign.email_campaign_recipients.pluck(:email)).to eq([ "ana@example.com" ])
        expect(campaign.email_campaign_recipients.first.contact_id).to be_in([ a.id, a.id + 1 ])
      end

      it "con fecha futura queda programada y el job la inicia a la hora" do
        create(:contact, tenant: tenant, email: "ana@example.com")
        campaign = create(:email_campaign, tenant: tenant, scheduled_at: 1.hour.from_now)
        campaign.launch!
        expect(campaign.reload).to be_status_scheduled
        expect(campaign.total_recipients).to eq(0)

        travel_to(2.hours.from_now) { EmailCampaignBatchJob.perform_now }
        expect(campaign.reload.total_recipients).to eq(1)
        expect(ses_requests(:send_email).size).to eq(1)
      end

      it "filtra por origen del contacto (archivo importado), incluidos los orígenes de fusiones" do
        create(:contact, tenant: tenant, email: "a@example.com", source_kind: "import", source_label: "Excel: expo.xlsx")
        merged = create(:contact, tenant: tenant, email: "b@example.com", source_kind: "web", source_label: "Landing")
        merged.update_column(:origins, [ { "kind" => "web", "label" => "Landing" },
                                         { "kind" => "import", "label" => "Excel: expo.xlsx" } ])
        create(:contact, tenant: tenant, email: "c@example.com", source_kind: "web", source_label: "Landing")

        campaign = create(:email_campaign, tenant: tenant, audience_filters: { "contact_origin" => "Excel: expo.xlsx" })
        campaign.launch!
        expect(campaign.email_campaign_recipients.pluck(:email)).to contain_exactly("a@example.com", "b@example.com")
      end

      it "filtra por etapa y origen del lead de las oportunidades" do
        pipeline = create(:pipeline_with_stages, tenant: tenant)
        stage    = pipeline.pipeline_stages.first
        source   = create(:lead_source, tenant: tenant, name: "Feria ISO", kind: "manual")
        inside   = create(:contact, tenant: tenant, email: "si@example.com")
        create(:opportunity, tenant: tenant, contact: inside, pipeline: pipeline, pipeline_stage: stage, lead_source: source)
        other = create(:contact, tenant: tenant, email: "no@example.com")
        create(:opportunity, tenant: tenant, contact: other, pipeline: pipeline, pipeline_stage: stage)

        campaign = create(:email_campaign, tenant: tenant,
                                           audience_filters: { "pipeline_stage_id" => stage.id, "lead_source_id" => source.id })
        campaign.launch!
        expect(campaign.email_campaign_recipients.pluck(:email)).to eq([ "si@example.com" ])
      end
    end
  end

  it "el HTML se limpia al guardar (sin scripts ni eventos)" do
    campaign = create(:email_campaign, tenant: tenant,
                                       body_html: %(<p onclick="x()">Hola</p><script>alert(1)</script><img src="https://x.test/a.png">))
    expect(campaign.body_html).to include("<p>Hola</p>", %(<img src="https://x.test/a.png">))
    expect(campaign.body_html).not_to include("script", "onclick")
  end

  it "#result_stats cuenta por resultado (clic > apertura; baja manda)" do
    campaign = create(:email_campaign, tenant: tenant, status: "running")
    create(:email_campaign_recipient, email_campaign: campaign, status: "delivered", opened_at: Time.current)
    create(:email_campaign_recipient, email_campaign: campaign, status: "delivered", clicked_at: Time.current)
    create(:email_campaign_recipient, email_campaign: campaign, status: "delivered", unsubscribed_at: Time.current)
    create(:email_campaign_recipient, email_campaign: campaign, status: "bounced")

    expect(campaign.result_stats).to include("opened" => 1, "clicked" => 1, "unsubscribed" => 1, "bounced" => 1,
                                             "total" => 4)
  end
end
