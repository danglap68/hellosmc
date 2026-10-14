require "rails_helper"

RSpec.describe BillVision::MerchantCatalog do
  it "includes every active business and active name alias, without identifiers or financial configuration" do
    merchant = create(:merchant, name: "Gat Tan Day Coffe", code: "GTD")
    create(:merchant_alias, merchant: merchant, alias: "GAT TAN DAY COFFEE", alias_type: "receipt_name")
    create(:merchant_alias, merchant: merchant, alias: "000123456", alias_type: "merchant_id")
    create(:merchant_alias, merchant: merchant, alias: "Old name", active: false)
    create(:merchant, name: "Inactive shop", active: false)
    other = create(:merchant, name: "Cherry Coffee")

    expect(described_class.call).to eq([
      { id: merchant.id, name: "Gat Tan Day Coffe", aliases: [ "GAT TAN DAY COFFEE" ] },
      { id: other.id, name: "Cherry Coffee", aliases: [] }
    ])
  end

  it "reflects additions and renames on the next request" do
    expect(described_class.call).to be_empty
    merchant = create(:merchant, name: "New coffee")
    expect(described_class.call.sole[:name]).to eq("New coffee")
    merchant.update!(name: "Updated coffee")
    expect(described_class.call.sole[:name]).to eq("Updated coffee")
  end
end
