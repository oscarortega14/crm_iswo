# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsApp::ConsentReply do
  describe ".classify" do
    it "reconoce negativas cortas, incluido el botón con coma de la plantilla" do
      ["No", "no.", "NO!", "No, autorizo", "No autorizo", "no gracias", "STOP", "Darme de baja"].each do |text|
        expect(described_class.classify(text)).to eq(:opt_out), "esperaba :opt_out para #{text.inspect}"
      end
    end

    it "reconoce autorizaciones explícitas, con o sin tilde" do
      ["Sí", "si", "Sí, autorizo", "SI AUTORIZO", "Acepto", "sí 👍"].each do |text|
        expect(described_class.classify(text)).to eq(:opt_in), "esperaba :opt_in para #{text.inspect}"
      end
    end

    it "no interpreta como consentimiento frases que solo contienen sí/no" do
      ["no sé, cuéntame más", "sí pero mañana", "hola", "", nil, "noviembre"].each do |text|
        expect(described_class.classify(text)).to be_nil, "esperaba nil para #{text.inspect}"
      end
    end
  end
end
