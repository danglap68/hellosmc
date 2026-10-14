require "rails_helper"

RSpec.describe RemitterTransfers::CodeMatcher do
  let(:codes) { %w[TK01 TK02 GT02 ML127] }

  def match(text, list = codes)
    described_class.call(text, codes: list)
  end

  it "finds the code anywhere in the caption, glued or spaced, any case" do
    [ "Nguyen Tri chuyen khoan nhanh qua Zalo TK01", "...ZALOTK01", "abc tk01", "tk 01", "TK-01 nhé" ].each do |text|
      expect(match(text).code).to eq("TK01"), text
    end
  end

  it "finds the code when the amount follows it" do
    [ "TK01 29.274.000", "tk01-29274000", "TK01: 29tr" ].each do |text|
      expect(match(text).code).to eq("TK01"), text
    end
  end

  it "accepts missing or extra leading zeros and returns the configured spelling" do
    [ "TK1", "tk 001", "TK-0001", "ZALOTK0001" ].each do |text|
      expect(match(text).code).to eq("TK01"), text
    end
    expect(match("TK001", %w[TK1]).code).to eq("TK1")
    expect(match("TK10", %w[TK010]).code).to eq("TK010")
  end

  it "never drops internal or trailing zeros, or consumes the start of an attached amount" do
    [ "TK10", "TK010", "TK0129274000", "TK00129274000" ].each do |text|
      expect(match(text).issue).to eq("code_missing"), text
    end
    expect(match("ML17").issue).to eq("code_missing")
    expect(match("ML102", %w[ML12]).issue).to eq("code_missing")
  end

  it "keeps conflicting zero-padded configurations ambiguous, including an exact spelling" do
    %w[TK1 TK01 TK001].each do |caption|
      expect(match(caption, %w[TK1 TK01]).issue).to eq("code_ambiguous")
    end
  end

  it "prefers a containing code only at the same occurrence, including zero padding variants" do
    expect(match("XTK001", %w[TK01 XTK1]).code).to eq("XTK1")
    expect(match("TK01 XTK01", %w[TK01 XTK01]).issue).to eq("code_ambiguous")
    expect(match("TK1 TK001").code).to eq("TK01")
  end

  it "tolerates a trailing character the user typed by mistake" do
    [ "TK01.", "TK01,", "TK01:", "TK01A" ].each do |text|
      expect(match(text).code).to eq("TK01"), text
    end
  end

  it "ignores diacritics" do
    expect(match("Chuyển tiền cho Chương TK02").code).to eq("TK02")
  end

  it "does not find TK01 inside TK010" do
    expect(match("TK010").issue).to eq("code_missing")
  end

  it "reads three-digit TID codes" do
    expect(match("ml127").code).to eq("ML127")
  end

  it "prefers the longer code when one contains the other" do
    expect(match("XTK01", %w[TK01 XTK01]).code).to eq("XTK01")
  end

  it "reports several different codes" do
    expect(match("TK01 GT02").issue).to eq("code_ambiguous")
  end

  it "reports a caption without a code" do
    expect(match("chuyen tien").issue).to eq("code_missing")
    expect(match(nil).issue).to eq("code_missing")
  end

  describe "strict mode (captions of senders who are not remitters)" do
    def strict(text)
      described_class.call(text, codes: %w[TK01 CH01], strict: true)
    end

    it "finds a code standing on its own" do
      [ "chuyen TK01", "TK01", "tk 01", "TK01: 29tr", "TK-01 nhé", "TK1", "tk 001" ].each do |text|
        expect(strict(text).code).to eq("TK01"), text
      end
    end

    it "does not read a code out of a longer word" do
      expect(strict("Bích 01").issue).to eq("code_missing")
      expect(strict("...ZALOTK01").issue).to eq("code_missing")
      expect(strict("TK01A").issue).to eq("code_missing")
      expect(strict("Bích 1").issue).to eq("code_missing")
      expect(strict("ZALOTK001").issue).to eq("code_missing")
    end

    it "reads the same captions loosely by default" do
      expect(match("Bích 01", %w[TK01 CH01]).code).to eq("CH01")
    end
  end

  it "uses the codes configured on the agent rows by default" do
    Workbook::Seed.call
    expect(described_class.call("TK01").code).to eq("TK01")

    MerchantDealer.find_by!(transfer_code: "TK01").update!(transfer_code: "TK91")
    expect(described_class.call("TK01").issue).to eq("code_missing")
    expect(described_class.call("chuyen TK91").code).to eq("TK91")
  end
end
