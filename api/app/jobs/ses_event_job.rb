# frozen_string_literal: true

# Procesa un evento de SES (entrega, rebote, queja, apertura, clic) recibido por SNS.
class SesEventJob < ApplicationJob
  queue_as :integrations

  def perform(event_json)
    EmailMarketing::EventProcessor.call(event_json)
  end
end
