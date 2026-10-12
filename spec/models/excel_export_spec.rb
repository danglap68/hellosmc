require "rails_helper"

RSpec.describe ExcelExport do
  it "defaults to the settlement file (Kết toán theo phí gốc), scheduled exports included" do
    expect(described_class.new.layout).to eq("ket_toan_phi_goc")
  end
end
