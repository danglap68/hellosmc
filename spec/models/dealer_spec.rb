require "rails_helper"

RSpec.describe Dealer do
  it "requires a complete bank profile before enabling QR preparation" do
    expect(build(:dealer, auto_payment_qr: true)).not_to be_valid
    expect(build(:dealer, bank_bin: "123456", bank_account_number: "000123", bank_account_name: "A")).not_to be_valid
    expect(build(:dealer, bank_bin: "970422", bank_account_number: "000123", bank_account_name: "A", auto_payment_qr: true)).to be_valid
  end

  it "finds missing recipient details independently of the automatic QR switch" do
    complete = create(:dealer, bank_bin: "970422", bank_account_number: "000123", bank_account_name: "NGUYEN VAN AN", auto_payment_qr: false)
    absent = create(:dealer)
    partial = create(:dealer)
    partial.update_columns(bank_bin: "unknown", bank_account_number: "000123", bank_account_name: " \t ")
    dealers = Dealer.where(id: [ complete.id, absent.id, partial.id ])

    expect(complete.missing_bank_profile_fields).to be_empty
    expect(absent.missing_bank_profile_fields).to eq(%i[bank_bin bank_account_number bank_account_name])
    expect(partial.missing_bank_profile_fields).to eq(%i[bank_bin bank_account_name])
    expect(dealers.with_bank_profile).to contain_exactly(complete)
    expect(dealers.without_bank_profile).to contain_exactly(absent, partial)
  end
  subject { build(:dealer) }

  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to have_many(:merchant_dealers) }
  it { is_expected.to have_many(:assigned_merchants) }

  it "normalizes the code to upper case and enforces uniqueness case-insensitively" do
    create(:dealer, code: "tran")
    duplicate = build(:dealer, code: "TRAN")
    expect(duplicate).not_to be_valid
    expect(Dealer.last.code).to eq("TRAN")
  end

  it "cannot be deleted while fee rules reference it" do
    dealer = create(:dealer)
    create(:fee_rule, dealer: dealer)
    expect(dealer.destroy).to be(false)
    expect(dealer.errors).to be_present
  end

  it "cannot be deleted while it is mapped to an HKD" do
    dealer = create(:dealer)
    create(:merchant_dealer, dealer: dealer)
    expect(dealer.destroy).to be(false)
    expect(dealer.errors).to be_present
    expect(MerchantDealer.where(dealer: dealer)).to exist
  end

  it "has many HKDs through merchant_dealers" do
    dealer = create(:dealer, name: "Cường Duyên")
    create(:merchant_dealer, dealer: dealer, merchant: create(:merchant, name: "Cường Duyên 1"))
    create(:merchant_dealer, dealer: dealer, merchant: create(:merchant, name: "Cường Duyên 2"))
    expect(dealer.assigned_merchants.count).to eq(2)
  end
end
