# frozen_string_literal: true

require "rails_helper"

RSpec.describe PipelineStage, type: :model do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:pipeline) { create(:pipeline, tenant: tenant) }

  subject { build(:pipeline_stage, tenant: tenant, pipeline: pipeline) }

  describe "asociaciones" do
    it { is_expected.to belong_to(:tenant).optional }
    it { is_expected.to belong_to(:pipeline) }
    it { is_expected.to have_many(:opportunities).dependent(:restrict_with_exception) }
  end

  describe "validaciones" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_numericality_of(:position).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:probability).only_integer.is_greater_than_or_equal_to(0).is_less_than_or_equal_to(100) }

    it "valida unicidad del nombre por pipeline (case-insensitive)" do
      create(:pipeline_stage, tenant: tenant, pipeline: pipeline, name: "Proposal")
      duplicate = build(:pipeline_stage, tenant: tenant, pipeline: pipeline, name: "PROPOSAL")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "permite mismo nombre en pipelines distintos" do
      other = create(:pipeline, tenant: tenant, name: "Otro pipeline")
      create(:pipeline_stage, tenant: tenant, pipeline: pipeline, name: "Proposal")
      other_stage = build(:pipeline_stage, tenant: tenant, pipeline: other, name: "Proposal")
      expect(other_stage).to be_valid
    end

    it "rechaza una etapa que sea closed_won y closed_lost a la vez" do
      stage = build(:pipeline_stage, tenant: tenant, pipeline: pipeline, closed_won: true, closed_lost: true)
      expect(stage).not_to be_valid
      expect(stage.errors[:base]).to be_present
    end
  end

  describe "scopes" do
    let!(:open_stage) { create(:pipeline_stage, tenant: tenant, pipeline: pipeline, closed_won: false, closed_lost: false) }
    let!(:won_stage)  { create(:pipeline_stage, :won,  tenant: tenant, pipeline: pipeline) }
    let!(:lost_stage) { create(:pipeline_stage, :lost, tenant: tenant, pipeline: pipeline) }

    it ".ordered las devuelve por position ascendente" do
      positions = PipelineStage.ordered.pluck(:position)
      expect(positions).to eq(positions.sort)
    end

    it ".open_stages excluye terminales" do
      expect(PipelineStage.open_stages).to include(open_stage)
      expect(PipelineStage.open_stages).not_to include(won_stage, lost_stage)
    end

    it ".terminal incluye closed_won o closed_lost" do
      expect(PipelineStage.terminal).to include(won_stage, lost_stage)
      expect(PipelineStage.terminal).not_to include(open_stage)
    end
  end

  describe "#terminal?" do
    it "es true para closed_won o closed_lost" do
      expect(build(:pipeline_stage, :won,  tenant: tenant, pipeline: pipeline)).to be_terminal
      expect(build(:pipeline_stage, :lost, tenant: tenant, pipeline: pipeline)).to be_terminal
    end

    it "es false para etapas regulares" do
      expect(build(:pipeline_stage, tenant: tenant, pipeline: pipeline)).not_to be_terminal
    end
  end

  describe "auto_rule" do
    it "acepta un disparador válido y lo expone en #auto_trigger" do
      stage = create(:pipeline_stage, tenant: tenant, pipeline: pipeline, auto_rule: { trigger: "whatsapp_inbound" })
      expect(stage.reload.auto_trigger).to eq("whatsapp_inbound")
    end

    it "normaliza trigger vacío a sin regla" do
      stage = create(:pipeline_stage, tenant: tenant, pipeline: pipeline, auto_rule: { "trigger" => "" })
      expect(stage.auto_rule).to eq({})
      expect(stage.auto_trigger).to be_nil
    end

    it "rechaza disparadores desconocidos" do
      stage = build(:pipeline_stage, tenant: tenant, pipeline: pipeline, auto_rule: { "trigger" => "magia" })
      expect(stage).not_to be_valid
    end

    it "rechaza reglas en etapas de cierre" do
      stage = build(:pipeline_stage, :won, tenant: tenant, pipeline: pipeline, auto_rule: { "trigger" => "bant_qualified" })
      expect(stage).not_to be_valid
    end

    it "no permite el mismo disparador en dos etapas del pipeline" do
      create(:pipeline_stage, tenant: tenant, pipeline: pipeline, auto_rule: { "trigger" => "bant_qualified" })
      dup = build(:pipeline_stage, tenant: tenant, pipeline: pipeline, auto_rule: { "trigger" => "bant_qualified" })
      expect(dup).not_to be_valid
    end
  end
end
