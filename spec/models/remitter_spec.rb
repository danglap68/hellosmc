require "rails_helper"

RSpec.describe Remitter do
  describe "validations" do
    it "requires name and excel_key" do
      remitter = build(:remitter, name: nil, excel_key: nil)
      expect(remitter).not_to be_valid
      expect(remitter.errors[:name]).to be_present
      expect(remitter.errors[:excel_key]).to be_present
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
