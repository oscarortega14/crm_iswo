# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::OpenaiClient — Chat Completions de OpenAI con herramientas
  # ==========================================================================
  # Modelo económico por defecto (línea «mini»); se cambia con OPENAI_MODEL
  # sin tocar código. Clave en OPENAI_API_KEY.
  #
  # Devuelve un Response con el mensaje del asistente (texto y/o llamadas a
  # herramientas) y el consumo de tokens, para el registro de costos.
  # ==========================================================================
  class OpenaiClient
    API_URL         = "https://api.openai.com/v1/chat/completions"
    DEFAULT_MODEL   = "gpt-4.1-mini"
    TIMEOUT_SECONDS = 30

    class Error < StandardError; end

    ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)
    Response = Struct.new(:content, :tool_calls, :raw_message, :input_tokens, :output_tokens, :model,
                          keyword_init: true)

    def self.api_key
      ENV["OPENAI_API_KEY"].to_s.strip.delete_prefix('"').delete_suffix('"').presence
    end

    def self.configured? = api_key.present?

    # OPENAI_BASE_URL permite un proxy/endpoint compatible (p. ej. Azure OpenAI o pruebas locales).
    def self.api_url
      base = ENV["OPENAI_BASE_URL"].to_s.strip.chomp("/")
      base.present? ? "#{base}/chat/completions" : API_URL
    end

    def self.model_name
      ENV["OPENAI_MODEL"].to_s.strip.presence || DEFAULT_MODEL
    end

    # messages: [{ role:, content:, tool_calls?:, tool_call_id? }]
    # tools:    [{ type: "function", function: { name:, description:, parameters: } }]
    def chat(messages:, tools: [], temperature: 0.4, max_tokens: 600)
      raise Error, "Falta OPENAI_API_KEY" unless self.class.configured?

      body = { model: self.class.model_name, messages: messages, temperature: temperature,
               max_tokens: max_tokens }
      body[:tools] = tools if tools.any?

      response = connection.post(self.class.api_url, body.to_json)
      data = JSON.parse(response.body.presence || "{}")
      raise Error, "OpenAI #{response.status}: #{data.dig('error', 'message') || response.body.to_s.truncate(200)}" unless response.success?

      message = data.dig("choices", 0, "message") || {}
      Response.new(
        content:       message["content"],
        tool_calls:    Array(message["tool_calls"]).map { |tc| parse_tool_call(tc) },
        raw_message:   message,
        input_tokens:  data.dig("usage", "prompt_tokens").to_i,
        output_tokens: data.dig("usage", "completion_tokens").to_i,
        model:         data["model"] || self.class.model_name
      )
    rescue Faraday::Error => e
      raise Error, "OpenAI no respondió: #{e.message}"
    end

    private

    def parse_tool_call(tc)
      args = JSON.parse(tc.dig("function", "arguments").presence || "{}")
      ToolCall.new(id: tc["id"], name: tc.dig("function", "name"), arguments: args)
    rescue JSON::ParserError
      ToolCall.new(id: tc["id"], name: tc.dig("function", "name"), arguments: {})
    end

    def connection
      Faraday.new(request: { timeout: TIMEOUT_SECONDS, open_timeout: 10 }) do |f|
        f.headers["Authorization"] = "Bearer #{self.class.api_key}"
        f.headers["Content-Type"]  = "application/json"
      end
    end
  end
end
