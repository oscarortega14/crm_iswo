# frozen_string_literal: true

require "rails_helper"

RSpec.describe RefreshDuplicateCacheJob, type: :job do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:pipeline) { create(:pipeline_with_stages, tenant: tenant) }

  def opp_for(contact)
    create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: contact, pipeline: pipeline,
                                            pipeline_stage: pipeline.pipeline_stages.first)
  end

  it "no lanza error en un tenant sin contactos" do
    expect { described_class.new.perform }.not_to raise_error
  end

  it "crea alertas para contactos recientes duplicados a nombre del admin del tenant" do
    admin = create(:user, :admin, tenant: tenant)
    opp_for(create(:contact, tenant: tenant, phone_e164: "+573009998877"))
    opp_for(create(:contact, tenant: tenant, phone_e164: "+573009998877"))

    expect { described_class.new.perform }.to change(DuplicateFlag, :count).by(1)
    expect(DuplicateFlag.last.detected_by_user_id).to eq(admin.id)
  end

  it "no hace nada en un tenant sin admin (detected_by_user es obligatorio)" do
    tenant.users.where(role: "admin").delete_all
    opp_for(create(:contact, tenant: tenant, phone_e164: "+573009998877"))
    opp_for(create(:contact, tenant: tenant, phone_e164: "+573009998877"))

    expect { described_class.new.perform }.not_to change(DuplicateFlag, :count)
  end
end
