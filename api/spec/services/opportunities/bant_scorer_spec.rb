# frozen_string_literal: true

require "rails_helper"

RSpec.describe Opportunities::BantScorer do
  let(:tenant) { ActsAsTenant.current_tenant }
  let!(:criterion) do
    create(:bant_criterion,
           tenant: tenant,
           budget_weight: 40, authority_weight: 20, need_weight: 20, timeline_weight: 20)
  end
  let(:opportunity) do
    create(:opportunity, tenant: tenant, estimated_value: 5_000_000, bant_data: bant_data)
  end

  describe "#call" do
    context "sin bant_data" do
      let(:bant_data) { {} }

      it "asume 50 por dimensión y pondera" do
        result = described_class.new(opportunity).call
        expect(result[:breakdown]).to eq(budget: 60, authority: 50, need: 50, timeline: 50)
        # 60*40 + 50*20 + 50*20 + 50*20 = 5400 → 54
        expect(result[:score]).to eq(54)
      end
    end

    context "con scores directos" do
      let(:bant_data) do
        {
          "budget"    => { "score" => 90 },
          "authority" => { "score" => 100 },
          "need"      => { "score" => 80 },
          "timeline"  => { "score" => 70 }
        }
      end

      it "usa los scores tal cual y aplica pesos" do
        result = described_class.new(opportunity).call
        expect(result[:breakdown]).to eq(budget: 90, authority: 100, need: 80, timeline: 70)
        # 90*40 + 100*20 + 80*20 + 70*20 = 3600 + 2000 + 1600 + 1400 = 8600 → 86
        expect(result[:score]).to eq(86)
      end
    end

    context "con respuestas cualitativas" do
      let(:bant_data) do
        {
          "budget"    => { "amount" => 20_000_000 },   # → 80
          "authority" => { "role"   => "gerente"    }, # → 90
          "need"      => { "intent" => "urgente"    }, # → 95
          "timeline"  => { "days"   => 5            }  # → 95
        }
      end

      it "traduce respuestas a puntajes" do
        result = described_class.new(opportunity).call
        expect(result[:breakdown]).to eq(budget: 80, authority: 90, need: 95, timeline: 95)
      end
    end

    context "timeline fuera de rangos" do
      let(:bant_data) { { "timeline" => { "days" => 365 } } }

      it "penaliza cierres muy lejanos" do
        result = described_class.new(opportunity).call
        expect(result[:breakdown][:timeline]).to eq(15)
      end
    end
  end

  describe "#call_and_persist!" do
    let(:bant_data) { { "budget" => { "score" => 100 } } }

    it "actualiza bant_score y guarda breakdown en bant_data" do
      described_class.new(opportunity).call_and_persist!
      opportunity.reload
      expect(opportunity.bant_score).to be_between(0, 100)
      expect(opportunity.bant_data["breakdown"]).to include("budget" => 100)
    end

    it "marca qualified=true cuando score >= threshold_qualified" do
      # score resultante: 100*40 + 50*20*3 = 7000 → 70, threshold=60 → qualified
      described_class.new(opportunity).call_and_persist!
      expect(opportunity.reload.qualified).to be true
    end

    it "marca qualified=false cuando score < threshold_qualified" do
      criterion.update!(threshold_qualified: 80)
      described_class.new(opportunity).call_and_persist!
      expect(opportunity.reload.qualified).to be false
    end
  end

  describe "#call_and_persist! — auto-avance a la etapa con disparador bant_qualified" do
    let(:pipeline) { create(:pipeline, tenant: tenant) }
    let!(:stage_nueva)      { create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Nueva",      position: 0, probability: 10) }
    let!(:stage_calificada) do
      create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Calificada", position: 2, probability: 50,
             auto_rule: { "trigger" => "bant_qualified" })
    end
    let!(:stage_propuesta)  { create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Propuesta",  position: 3, probability: 75) }
    let!(:stage_ganada)     { create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Ganada",     position: 4, probability: 100, closed_won: true) }

    let(:opp) do
      create(:opportunity, :skip_bant_recalc, tenant: tenant, pipeline: pipeline, pipeline_stage: stage_nueva,
             bant_data: { "budget" => { "score" => 100 }, "authority" => { "score" => 100 },
                          "need" => { "score" => 100 }, "timeline" => { "score" => 100 } })
    end

    before { criterion.update!(threshold_qualified: 60) }

    it "avanza a Calificada cuando supera el umbral por primera vez" do
      expect { described_class.new(opp).call_and_persist! }
        .to change { opp.reload.pipeline_stage_id }.to(stage_calificada.id)
    end

    it "registra un opportunity_log de stage_change con nota automática" do
      expect { described_class.new(opp).call_and_persist! }
        .to change { opp.opportunity_logs.where(action: "stage_change").count }.by(1)

      log = opp.opportunity_logs.last
      expect(log.note).to match(/automático/i)
      expect(log.changes_data["to_stage_id"]).to eq(stage_calificada.id)
    end

    it "NO avanza si ya estaba calificada (qualified=true)" do
      opp.update!(qualified: true, pipeline_stage: stage_calificada)
      expect { described_class.new(opp).call_and_persist! }
        .not_to change { opp.reload.pipeline_stage_id }
    end

    it "NO avanza si ninguna etapa tiene el disparador bant_qualified" do
      stage_calificada.update!(auto_rule: {})
      expect { described_class.new(opp).call_and_persist! }
        .not_to change { opp.reload.pipeline_stage_id }
    end

    it "NO avanza si la etapa actual ya está en posición >= Calificada" do
      opp.update!(pipeline_stage: stage_propuesta)
      expect { described_class.new(opp).call_and_persist! }
        .not_to change { opp.reload.pipeline_stage_id }
    end

    it "NO avanza si la etapa actual es terminal (won)" do
      opp.update!(pipeline_stage: stage_ganada, status: "won", qualified: false)
      expect { described_class.new(opp).call_and_persist! }
        .not_to change { opp.reload.pipeline_stage_id }
    end

    it "NO avanza si el score no supera el umbral" do
      low_opp = create(:opportunity, :skip_bant_recalc, tenant: tenant, pipeline: pipeline, pipeline_stage: stage_nueva,
                        bant_data: { "budget" => { "score" => 0 }, "authority" => { "score" => 0 },
                                     "need" => { "score" => 0 }, "timeline" => { "score" => 0 } })
      expect { described_class.new(low_opp).call_and_persist! }
        .not_to change { low_opp.reload.pipeline_stage_id }
    end
  end

  describe "fallback sin BantCriterion" do
    before do
      criterion.destroy
      tenant.association(:bant_criterion).reset
    end

    let(:bant_data) { {} }

    it "usa pesos 25/25/25/25 como default" do
      result = described_class.new(opportunity).call
      # Sin data: budget=60 (estimated_value 5M → rango 1M..10M), resto=50.
      # 60*25 + 50*25*3 = 1500 + 3750 = 5250 → 53
      expect(result[:score]).to eq(53)
    end
  end
end
