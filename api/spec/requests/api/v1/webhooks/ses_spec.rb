# frozen_string_literal: true

require "rails_helper"
require "aws-sdk-sns"

RSpec.describe "Api::V1::Webhooks::Ses", type: :request do
  let(:verifier) { instance_double(Aws::SNS::MessageVerifier, authentic?: true) }

  before { allow(Aws::SNS::MessageVerifier).to receive(:new).and_return(verifier) }

  def sns(type, extra = {})
    { "Type" => type, "TopicArn" => "arn:aws:sns:us-east-1:1:ses-marketing" }.merge(extra).to_json
  end

  it "Notification encola el evento de SES" do
    post "/api/v1/webhooks/ses", params: sns("Notification", "Message" => { eventType: "Delivery" }.to_json),
                                 headers: { "CONTENT_TYPE" => "text/plain" }
    expect(response).to have_http_status(:ok)
    expect(SesEventJob).to have_been_enqueued.with({ eventType: "Delivery" }.to_json)
  end

  it "confirma la suscripción solo contra un host de SNS" do
    stub = stub_request(:get, "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=x")
    post "/api/v1/webhooks/ses", params: sns("SubscriptionConfirmation",
                                             "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=x")
    expect(stub).to have_been_requested

    post "/api/v1/webhooks/ses", params: sns("SubscriptionConfirmation", "SubscribeURL" => "https://evil.test/x")
    expect(response).to have_http_status(:ok)
  end

  it "403 si la firma no es válida o el tema no es el configurado" do
    allow(verifier).to receive(:authentic?).and_return(false)
    post "/api/v1/webhooks/ses", params: sns("Notification", "Message" => "{}")
    expect(response).to have_http_status(:forbidden)

    allow(verifier).to receive(:authentic?).and_return(true)
    stub_const("ENV", ENV.to_h.merge("SES_SNS_TOPIC_ARN" => "arn:aws:sns:us-east-1:1:otro"))
    post "/api/v1/webhooks/ses", params: sns("Notification", "Message" => "{}")
    expect(response).to have_http_status(:forbidden)
  end
end
