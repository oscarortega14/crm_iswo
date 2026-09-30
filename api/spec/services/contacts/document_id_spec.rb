# frozen_string_literal: true

require "rails_helper"

RSpec.describe Contacts::DocumentId do
  def classify(raw) = described_class.classify(raw)&.then { |r| [ r.number, r.kind ] }

  it "cédulas → persona natural (con o sin puntos y prefijo)" do
    expect(classify("1020304050")).to eq([ "1020304050", "person" ])
    expect(classify("79.123.456")).to eq([ "79123456", "person" ])
    expect(classify("CC 1.020.304.050")).to eq([ "1020304050", "person" ])
    expect(classify("C.C. 52123456")).to eq([ "52123456", "person" ])
  end

  it "NIT → empresa (con dígito de verificación, prefijo o rango 8xx/9xx de 9 dígitos)" do
    expect(classify("900.123.456-7")).to eq([ "900123456-7", "company" ])
    expect(classify("NIT 830123456")).to eq([ "830123456", "company" ])
    expect(classify("901234567")).to eq([ "901234567", "company" ])
  end

  it "vacío o sin dígitos → nil" do
    expect(classify("")).to be_nil
    expect(classify("N/A")).to be_nil
  end
end
