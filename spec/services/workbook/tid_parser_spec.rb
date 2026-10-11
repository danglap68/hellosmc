require "rails_helper"

RSpec.describe Workbook::TidParser do
  describe ".call" do
    it "parses a dash suffix on the merchant name" do
      expect(described_class.call("HỘ KINH DOANH THIÊN KIM GV-1")).to eq("tid1")
    end

    it "parses a tid suffix" do
      expect(described_class.call("HỘ KINH DOANH THIÊN KIM GV tid3")).to eq("tid3")
    end

    it "parses TID with a number, case-insensitive" do
      expect(described_class.call("Chị Huệ (TID 127)")).to eq("tid127")
      expect(described_class.call("TID 127")).to eq("tid127")
    end

    it "parses a terminal prefix" do
      expect(described_class.call("terminal:128")).to eq("tid128")
    end

    it "uses the number after the dash when present" do
      expect(described_class.call("HKD AS CAFE-2")).to eq("tid2")
      expect(described_class.call("HKD AS CAFE - 12")).to eq("tid12")
    end

    it "falls back to the trailing number of the name" do
      expect(described_class.call("CHERRY COFFE 2")).to eq("tid2")
      expect(described_class.call("CHERRY COFFEE (2)")).to eq("tid2")
      expect(described_class.call("HKD AS CAFE 2")).to eq("tid2")
    end

    it "does not read digits glued to a word" do
      expect(described_class.call("CAFE24")).to be_nil
    end

    it "returns nil without a suffix" do
      expect(described_class.call("HỘ KINH DOANH THIÊN KIM GV")).to be_nil
    end

    it "returns nil for blank text" do
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call("")).to be_nil
    end
  end

  describe ".strip_bare_number" do
    it "removes a bare trailing number" do
      expect(described_class.strip_bare_number("CHERRY COFFE 2")).to eq("CHERRY COFFE")
      expect(described_class.strip_bare_number("CHERRY COFFEE (2)")).to eq("CHERRY COFFEE")
    end

    it "also strips a dash suffix" do
      expect(described_class.strip_bare_number("THIÊN KIM GV-1")).to eq("THIÊN KIM GV")
    end
  end
end
