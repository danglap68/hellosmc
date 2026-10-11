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
      [ "chuyen TK01", "TK01", "tk 01", "TK01: 29tr", "TK-01 nhé" ].each do |text|
        expect(strict(text).code).to eq("TK01"), text
      end
    end

    it "does not read a code out of a longer word" do
      expect(strict("Bích 01").issue).to eq("code_missing")
      expect(strict("...ZALOTK01").issue).to eq("code_missing")
      expect(strict("TK01A").issue).to eq("code_missing")
    end

    it "reads the same captions loosely by default" do
      expect(match("Bích 01", %w[TK01 CH01]).code).to eq("CH01")
    end
  end

  it "uses the configured table by default" do
    expect(described_class.call("TK01").code).to eq("TK01")
  end
end
