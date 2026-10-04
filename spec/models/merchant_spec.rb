require "rails_helper"

RSpec.describe Merchant do
  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to belong_to(:dealer).optional }

  it "stores a diacritic-free normalized name" do
    merchant = create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV")
    expect(merchant.normalized_name).to eq("001 ho kinh doanh thien kim gv")
    expect(merchant.core_name).to eq("thien kim gv")
  end

  it "requires a unique code" do
    create(:merchant, code: "001")
    expect(build(:merchant, code: "001")).not_to be_valid
  end
end
