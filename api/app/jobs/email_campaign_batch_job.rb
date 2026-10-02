# frozen_string_literal: true

# ============================================================================
# EmailCampaignBatchJob — inicia campañas programadas y despacha un lote por
# campaña "running" (recurring, cada minuto).
# ============================================================================
class EmailCampaignBatchJob < ApplicationJob
  queue_as :integrations

  def perform
    ActsAsTenant.without_tenant do
      EmailCampaign.status_scheduled.where(scheduled_at: ..Time.current).find_each do |campaign|
        ActsAsTenant.with_tenant(campaign.tenant) { start_scheduled(campaign) }
      end

      EmailCampaign.status_running.find_each do |campaign|
        ActsAsTenant.with_tenant(campaign.tenant) { EmailCampaigns::Dispatcher.call(campaign: campaign) }
      end
    end
  end

  private

  def start_scheduled(campaign)
    campaign.start!
  rescue StandardError => e
    Rails.logger.error("[EmailCampaignBatchJob] no se pudo iniciar la campaña #{campaign.id}: #{e.message}")
  end
end
