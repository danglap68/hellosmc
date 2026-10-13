require "rails_helper"

RSpec.describe BillVision::Prompt do
  let(:document_schema) { described_class::SCHEMA.dig(:properties, :documents, :items) }

  it "asks for the success wording and the QR code on every document, as required nullable booleans" do
    expect(document_schema[:required]).to include(*described_class::TRANSFER_FLAGS)
    described_class::TRANSFER_FLAGS.each do |flag|
      expect(document_schema.dig(:properties, flag.to_sym, :type)).to eq(%w[boolean null])
    end
  end

  it "tells the model a QR code page is not a transfer and a transfer must say it succeeded" do
    expect(described_class::SYSTEM).to include("QUÉT ĐỂ THANH TOÁN", "CHUYỂN TIỀN THÀNH CÔNG", "shows_qr_code", "shows_success_message")
  end

  it "asks for the bank brand apart from the merchant name, and the name after TÊN ĐẠI LÝ" do
    expect(described_class::SYSTEM).to include("bill_bank_name", "TÊN ĐẠI LÝ", "never the bank logo")
    expect(document_schema.dig(:properties, :bill_bank_name, :type)).to eq(%w[string null])
  end

  it "keeps every schema property required (OpenAI strict mode)" do
    expect(document_schema[:required].sort).to eq(document_schema[:properties].keys.map(&:to_s).sort)
  end
end
