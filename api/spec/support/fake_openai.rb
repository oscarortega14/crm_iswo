# frozen_string_literal: true

# Cliente OpenAI simulado para los specs del asistente IA: devuelve las
# respuestas en el orden dado y guarda lo que recibió.
class FakeOpenaiClient
  attr_reader :requests

  # responses: [{ content: "…" } | { tool_calls: [{ name:, arguments: {} }] }]
  def initialize(*responses)
    @responses = responses
    @requests = []
  end

  def chat(messages:, tools: [], **)
    @requests << { messages: messages.map(&:dup), tools: tools }
    spec = @responses.shift || { content: "" }
    calls = Array(spec[:tool_calls]).each_with_index.map do |tc, i|
      AiAgent::OpenaiClient::ToolCall.new(id: "call_#{i}", name: tc[:name], arguments: tc[:arguments].stringify_keys)
    end
    raw = { "role" => "assistant", "content" => spec[:content] }
    if calls.any?
      raw["tool_calls"] = calls.map do |c|
        { "id" => c.id, "type" => "function", "function" => { "name" => c.name, "arguments" => c.arguments.to_json } }
      end
    end
    AiAgent::OpenaiClient::Response.new(content: spec[:content], tool_calls: calls, raw_message: raw,
                                        input_tokens: 1000, output_tokens: 50, model: "gpt-4.1-mini")
  end
end
