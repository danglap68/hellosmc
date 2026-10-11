require "rails_helper"

RSpec.describe Telegram::ChatNameParser do
  it "splits TenDaiLy-HKD1-HKD2" do
    result = described_class.call("Anh Trân-Thiên Kim GV-Cherry Cofee")
    expect(result.agent_token).to eq("Anh Trân")
    expect(result.merchant_tokens).to eq([ "Thiên Kim GV", "Cherry Cofee" ])
  end

  it "treats HKD2 as optional" do
    result = described_class.call("Anh Trân-Thiên Kim GV")
    expect(result.merchant_tokens).to eq([ "Thiên Kim GV" ])
  end

  it "tolerates spaces and en/em dashes around separators" do
    result = described_class.call("Anh Trân - Thiên Kim GV – Cherry Cofee")
    expect(result.agent_token).to eq("Anh Trân")
    expect(result.merchant_tokens.size).to eq(2)
  end

  it "returns only an agent token when there is no separator" do
    result = described_class.call("Bill group")
    expect(result.agent_token).to eq("Bill group")
    expect(result.merchant_tokens).to eq([])
  end

  it "returns nothing for a blank name" do
    expect(described_class.call(nil)).not_to be_present
    expect(described_class.call("  ")).not_to be_present
  end
end
