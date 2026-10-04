require "rails_helper"

RSpec.describe MerchantAlias do
  it "normalizes name aliases" do
    merchant_alias = create(:merchant_alias, alias: "Hộ Kinh Doanh  Thiên-Kim")
    expect(merchant_alias.normalized_alias).to eq("ho kinh doanh thien kim")
  end

  it "normalizes identifier aliases to compact alphanumerics" do
    merchant_alias = create(:merchant_alias, alias_type: "merchant_id", alias: " 0000-0012 3456 ")
    expect(merchant_alias.normalized_alias).to eq("000000123456")
  end

  it "rejects the same alias pointing to a different merchant" do
    create(:merchant_alias, alias: "THIEN KIM")
    clash = build(:merchant_alias, alias: "Thiên Kim")
    expect(clash).not_to be_valid
    expect(clash.errors[:alias]).to be_present
  end

  it "allows the same alias once the other one is inactive" do
    create(:merchant_alias, alias: "THIEN KIM", active: false)
    expect(build(:merchant_alias, alias: "Thiên Kim")).to be_valid
  end

  it "rejects unknown alias types" do
    expect(build(:merchant_alias, alias_type: "nickname")).not_to be_valid
  end
end
