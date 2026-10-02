# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailMarketing::Renderer do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:campaign) do
    build(:email_campaign, tenant: tenant, subject: "Hola {{nombre|cliente}}", preheader: "Novedades ISO",
                           body_html: "<p>Hola {{ nombre }} {{apellido}} de {{empresa|tu empresa}}</p>")
  end

  before { verify_email_sender!(tenant, "from_name" => "ISWO", "address" => "Calle 1 # 2-3, Bogotá") }

  it "reemplaza variables (escapando HTML), usa valores por defecto y agrega pie con baja" do
    contact = build(:contact, tenant: tenant, first_name: "<Ana>", last_name: "Ruiz", company_name: nil)
    result = described_class.call(campaign: campaign, contact: contact, unsubscribe_url: "https://x.test/baja?t=1")

    expect(result.subject).to eq("Hola <Ana>")
    expect(result.html).to include("Hola &lt;Ana&gt; Ruiz de tu empresa")
    expect(result.html).to include("Novedades ISO", "Calle 1 # 2-3, Bogotá", 'href="https://x.test/baja?t=1"')
    expect(result.text).to include("Hola <Ana> Ruiz de tu empresa", "Darme de baja: https://x.test/baja?t=1")
    expect(result.html).to include("<title>Hola &lt;Ana&gt;</title>")
  end

  it "en empresas {{nombre}} es la razón social y sin nombre usa el valor por defecto" do
    company = build(:contact, tenant: tenant, kind: "company", first_name: nil, company_name: "Andina SAS")
    expect(described_class.call(campaign: campaign, contact: company).subject).to eq("Hola Andina SAS")

    nameless = build(:contact, tenant: tenant, first_name: nil, last_name: nil, email: "a@b.co")
    expect(described_class.call(campaign: campaign, contact: nameless).subject).to eq("Hola cliente")
  end

  it "la versión en texto respeta los saltos de línea del editor" do
    campaign.body_html = %(<p>Un saludo,<br style="">El equipo</p>)
    expect(described_class.call(campaign: campaign, contact: build(:contact, tenant: tenant)).text)
      .to start_with("Un saludo,\nEl equipo")
  end

  it "deja intactas las llaves que no son variables conocidas" do
    campaign.body_html = "<p>{{desconocida}}</p>"
    expect(described_class.call(campaign: campaign, contact: build(:contact, tenant: tenant)).html)
      .to include("{{desconocida}}")
  end
end
