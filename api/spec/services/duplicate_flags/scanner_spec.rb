# frozen_string_literal: true

require "rails_helper"

RSpec.describe DuplicateFlags::Scanner do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:admin)    { create(:user, :admin, tenant: tenant) }
  let(:pipeline) { create(:pipeline_with_stages, tenant: tenant) }

  def opp_for(contact, created_at: Time.current, **attrs)
    create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: contact, pipeline: pipeline,
                                            pipeline_stage: pipeline.pipeline_stages.first, created_at: created_at, **attrs)
  end

  def scan = described_class.call(tenant: tenant, actor: admin)

  it "detecta contactos DISTINTOS con el mismo celular (antes el escaneo no los veía)" do
    older = opp_for(create(:contact, tenant: tenant, first_name: "Ana", phone_e164: "+573001112233"), created_at: 2.days.ago)
    newer = opp_for(create(:contact, tenant: tenant, first_name: "Ana M", phone_e164: "+573001112233"))

    expect(scan.created).to eq(1)
    flag = DuplicateFlag.last
    expect(flag).to have_attributes(opportunity_id: newer.id, duplicate_of_opportunity_id: older.id,
                                    matched_on: "phone", detected_by_user_id: admin.id, resolution: "pending")
  end

  it "detecta contactos distintos con el mismo correo (sin distinguir mayúsculas)" do
    opp_for(create(:contact, tenant: tenant, email: "laura@correo.co"), created_at: 1.day.ago)
    opp_for(create(:contact, tenant: tenant, email: "Laura@Correo.co"))

    expect(scan.created).to eq(1)
    expect(DuplicateFlag.last.matched_on).to eq("email")
  end

  it "detecta el mismo contacto con dos oportunidades abiertas" do
    contact = create(:contact, tenant: tenant, phone_e164: "+573004445566")
    opp_for(contact, created_at: 1.day.ago)
    opp_for(contact)

    expect(scan.created).to eq(1)
  end

  it "no repite alertas ya existentes (ni siquiera las ignoradas) y es idempotente" do
    older = opp_for(create(:contact, tenant: tenant, phone_e164: "+573007778899"), created_at: 1.day.ago)
    newer = opp_for(create(:contact, tenant: tenant, phone_e164: "+573007778899"))
    create(:duplicate_flag, tenant: tenant, opportunity: older, duplicate_of_opportunity: newer, resolution: "ignored")

    expect(scan.created).to eq(0)
    expect(scan.created).to eq(0)
  end

  it "ignora contactos eliminados y oportunidades cerradas" do
    kept = create(:contact, tenant: tenant, phone_e164: "+573001230000")
    gone = create(:contact, tenant: tenant, phone_e164: "+573001230000")
    opp_for(kept)
    opp_for(gone)
    gone.discard
    won = create(:contact, tenant: tenant, email: "x@y.co")
    opp_for(won, status: "won")
    opp_for(create(:contact, tenant: tenant, email: "x@y.co"))

    expect(scan.created).to eq(0)
  end
end
