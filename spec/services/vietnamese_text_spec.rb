require "rails_helper"

RSpec.describe VietnameseText do
  it "removes diacritics including đ" do
    expect(described_class.normalize("Cường Duyên ĐẠI LÝ")).to eq("cuong duyen dai ly")
  end

  it "extracts the core business name" do
    expect(described_class.core_name("001_ HỘ KINH DOANH THIÊN KIM GV")).to eq("thien kim gv")
    expect(described_class.core_name("HKD Trân 3")).to eq("tran 3")
    expect(described_class.core_name("Công ty TNHH Cherry")).to eq("cherry")
  end

  it "normalizes identifiers" do
    expect(described_class.normalize_identifier("mid: 0001-23 ab")).to eq("MID000123AB")
  end

  it "computes a similarity ratio" do
    expect(described_class.similarity("thien kim gv", "thien kim gv")).to eq(1.0)
    expect(described_class.similarity("thien kim gv", "thien kin gv")).to be > 0.9
    expect(described_class.similarity("thien kim gv", "cuong duyen")).to be < 0.5
  end
end
