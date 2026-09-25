# frozen_string_literal: true

# ============================================================================
# WhatsappCampaignBatchJob — despacha un lote por campaña "running" (recurring)
# ============================================================================
class WhatsappCampaignBatchJob < ApplicationJob
  queue_as :integrations

  def perform
    ActsAsTenant.without_tenant do
      WhatsappCampaign.status_running.find_each do |campaign|
        ActsAsTenant.with_tenant(campaign.tenant) do
          WhatsappCampaigns::Dispatcher.call(campaign: campaign)
        end
      end
    end
  end
end
