require "rails_helper"

RSpec.describe Dealer do
  subject { build(:dealer) }

  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to have_many(:merchants) }
  it { is_expected.to have_many(:telegram_chats) }

  it "normalizes the code to upper case and enforces uniqueness case-insensitively" do
    create(:dealer, code: "tran")
    duplicate = build(:dealer, code: "TRAN")
    expect(duplicate).not_to be_valid
    expect(Dealer.last.code).to eq("TRAN")
  end

  it "cannot be deleted while merchants reference it" do
    dealer = create(:dealer)
    create(:merchant, dealer: dealer)
    expect(dealer.destroy).to be(false)
    expect(dealer.errors).to be_present
  end

  it "is a separate entity from merchants: one dealer has many HKDs" do
    dealer = create(:dealer, name: "Cường Duyên")
    create(:merchant, name: "Cường Duyên 1", dealer: dealer)
    create(:merchant, name: "Cường Duyên 2", dealer: dealer)
    expect(dealer.merchants.count).to eq(2)
  end
end
