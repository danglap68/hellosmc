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

    it "returns nil without a suffix" do
      expect(described_class.call("HỘ KINH DOANH THIÊN KIM GV")).to be_nil
    end

    it "returns nil for blank text" do
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call("")).to be_nil
    end
  end
end
