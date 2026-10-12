require "rails_helper"

RSpec.describe Remitter do
  describe "validations" do
    it "requires name and excel_key" do
      remitter = build(:remitter, name: nil, excel_key: nil)
      expect(remitter).not_to be_valid
      expect(remitter.errors[:name]).to be_present
      expect(remitter.errors[:excel_key]).to be_present
    end

    it "takes the thu chi column from the name when left blank (R3)" do
      remitter = build(:remitter, name: "Lập", excel_key: "")
      remitter.valid?
      expect(remitter.excel_key).to eq("LẬP")
    end

    it "fills the username from the person's Telegram messages (R2)" do
      create(:telegram_message, telegram_sender_id: 777, telegram_username: "laplap")
      remitter = build(:remitter, telegram_user_id: 777, telegram_username: nil)
      remitter.valid?
      expect(remitter.telegram_username).to eq("laplap")
    end

    it "suggests people who wrote in the groups and are not remitters yet (R1)" do
      create(:telegram_message, telegram_sender_id: 777, sender_name: "Lập", telegram_username: "laplap")
      create(:telegram_message, telegram_sender_id: 888, sender_name: "Kim")
      create(:remitter, telegram_user_id: 888)

      suggestions = described_class.telegram_sender_suggestions
      expect(suggestions.map(&:id)).to eq([ 777 ])
      expect(suggestions.first.label).to eq("Lập @laplap")
    end

    it "normalizes excel_key to uppercase and trims whitespace" do
      remitter = build(:remitter, excel_key: " lập ")
      remitter.valid?
      expect(remitter.excel_key).to eq("LẬP")
    end

    it "normalizes telegram_username to lowercase and strips the @ prefix" do
      remitter = build(:remitter, telegram_username: "  @Lap ")
      remitter.valid?
      expect(remitter.telegram_username).to eq("lap")
    end

    it "rejects a duplicate excel_key case-insensitively" do
      create(:remitter, excel_key: "LẬP")
      expect(build(:remitter, excel_key: "lập")).not_to be_valid
    end

    it "rejects a duplicate telegram_user_id" do
      create(:remitter, telegram_user_id: 123)
      expect(build(:remitter, telegram_user_id: 123)).not_to be_valid
    end

    it "allows multiple remitters with a nil telegram_user_id" do
      create(:remitter, telegram_user_id: nil)
      expect(build(:remitter, telegram_user_id: nil)).to be_valid
    end
  end
end
