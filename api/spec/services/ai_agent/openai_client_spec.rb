# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiAgent::OpenaiClient do
  around do |example|
    ENV["OPENAI_API_KEY"] = "sk-test"
    example.run
  ensure
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("OPENAI_MODEL")
  end

  it "envía el modelo mini por defecto y lee texto, herramientas y tokens" do
    stub = stub_request(:post, described_class::API_URL)
           .with(headers: { "Authorization" => "Bearer sk-test" }) { |req| JSON.parse(req.body)["model"] == "gpt-4.1-mini" }
           .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
             model: "gpt-4.1-mini-2025-04-14",
             choices: [ { message: { role: "assistant", content: nil, tool_calls: [
               { id: "c1", type: "function", function: { name: "calificar_lead", arguments: '{"temperatura":"hot"}' } }
             ] } } ],
             usage: { prompt_tokens: 812, completion_tokens: 21 }
           }.to_json)

    response = described_class.new.chat(messages: [ { role: "user", content: "hola" } ],
                                        tools: AiAgent::Tools::DEFINITIONS)

    expect(stub).to have_been_requested
    expect(response.tool_calls.first).to have_attributes(name: "calificar_lead", arguments: { "temperatura" => "hot" })
    expect(response).to have_attributes(input_tokens: 812, output_tokens: 21, model: "gpt-4.1-mini-2025-04-14")
  end

  it "OPENAI_MODEL cambia el modelo; errores de la API se reportan claros" do
    ENV["OPENAI_MODEL"] = "gpt-4o-mini"
    stub_request(:post, described_class::API_URL)
      .with { |req| JSON.parse(req.body)["model"] == "gpt-4o-mini" }
      .to_return(status: 401, body: { error: { message: "Incorrect API key" } }.to_json)

    expect { described_class.new.chat(messages: []) }.to raise_error(described_class::Error, /401: Incorrect API key/)
  end

  it "sin clave no llama a OpenAI" do
    ENV.delete("OPENAI_API_KEY")
    expect(described_class.configured?).to be(false)
    expect { described_class.new.chat(messages: []) }.to raise_error(described_class::Error, /OPENAI_API_KEY/)
  end
end
