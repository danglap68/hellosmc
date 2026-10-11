require "rails_helper"

RSpec.describe TelegramChat do
  let!(:tran) { create(:dealer, name: "Anh Trân", code: "TRAN") }
  let!(:thien_kim) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }
  let!(:cherry) { create(:merchant, name: "002_ CHERRY COFEE", code: "002") }

  before do
    create(:merchant_alias, merchant: thien_kim, alias: "THIÊN KIM GV", alias_type: "receipt_name")
    create(:merchant_alias, merchant: cherry, alias: "CHERRY COFEE", alias_type: "receipt_name")
  end

  describe "#group_dealer" do
    it "matches the agent in the title by name, ignoring case and diacritics" do
      expect(build(:telegram_chat, name: "anh tran-Thiên Kim GV").group_dealer).to eq(tran)
    end

    it "matches the agent by code" do
      expect(build(:telegram_chat, name: "TRAN-Thiên Kim GV").group_dealer).to eq(tran)
    end

    it "is nil for an unknown agent" do
      expect(build(:telegram_chat, name: "Bill group").group_dealer).to be_nil
    end

    it "is nil when two dealers match" do
      create(:dealer, name: "ANH TRAN", code: "TRAN2")
      expect(build(:telegram_chat, name: "Anh Trân-Thiên Kim GV").group_dealer).to be_nil
    end

    it "forgets the memoized agent on reload" do
      chat = build(:telegram_chat, name: "Anh Trân-Thiên Kim GV")
      expect(chat.group_dealer).to eq(tran)
      tran.update!(active: false)
      expect(chat.group_dealer).to eq(tran) # memoized for this instance
      chat.save!
      expect(chat.reload.group_dealer).to be_nil
    end

    it "ignores inactive dealers" do
      tran.update!(active: false)
      expect(build(:telegram_chat, name: "Anh Trân-Thiên Kim GV").group_dealer).to be_nil
    end
  end

  describe "#name_merchants" do
    it "suggests every HKD named in the title" do
      chat = build(:telegram_chat, name: "Anh Trân-Thiên Kim GV-Cherry Cofee")
      expect(chat.name_merchants).to contain_exactly(thien_kim, cherry)
    end

    it "skips tokens that match no merchant" do
      chat = build(:telegram_chat, name: "Anh Trân-Thiên Kim GV-Không có")
      expect(chat.name_merchants).to eq([ thien_kim ])
    end

    it "joins dash-split tokens when the HKD name itself contains a dash" do
      dashed = create(:merchant, code: "DASH1", name: "NCT-MBV")
      chat = build(:telegram_chat, name: "Anh Trân-NCT-MBV-Thiên Kim GV")
      expect(chat.name_merchants).to contain_exactly(dashed, thien_kim)
    end
  end

  describe "merchants" do
    it "serves several HKDs" do
      chat = create(:telegram_chat, merchants: [ thien_kim, cherry ])
      expect(chat.reload.merchants).to contain_exactly(thien_kim, cherry)
    end

    it "is unmapped until an HKD is assigned" do
      chat = create(:telegram_chat)
      expect(described_class.unmapped).to include(chat)
      chat.update!(merchants: [ cherry ])
      expect(described_class.unmapped).not_to include(chat)
    end

    it "flags a configured list that differs from the title" do
      chat = create(:telegram_chat, name: "Anh Trân-Thiên Kim GV-Cherry Cofee", merchants: [ thien_kim ])
      expect(chat.merchant_ids_differ_from_name?).to be(true)
      chat.update!(merchants: [ thien_kim, cherry ])
      expect(chat.merchant_ids_differ_from_name?).to be(false)
    end
  end

  describe "#audit_snapshot" do
    it "includes the sorted HKD ids" do
      chat = create(:telegram_chat, merchants: [ cherry, thien_kim ])
      expect(chat.audit_snapshot["merchant_ids"]).to eq([ thien_kim.id, cherry.id ].sort)
      expect(Audit::Snapshot.of(chat)).to include("merchant_ids")
    end
  end
end
