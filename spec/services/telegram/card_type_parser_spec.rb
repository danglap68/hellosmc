require "rails_helper"

RSpec.describe Telegram::CardTypeParser do
  before do
    create(:normal_card_type)
    create(:mb_card_type)
    create(:napas_card_type)
  end

  it "detects MB in any case" do
    expect(described_class.call("MB")).to eq([ "mb" ])
    expect(described_class.call("bill mb nhé")).to eq([ "mb" ])
    expect(described_class.call("#MB.")).to eq([ "mb" ])
  end

  it "detects Napas" do
    expect(described_class.call("Napas")).to eq([ "napas" ])
    expect(described_class.call("NAPAS - Cường Duyên 2")).to eq([ "napas" ])
  end

  it "does not match tags inside other words" do
    expect(described_class.call("member bill")).to eq([])
    expect(described_class.call("snapashot")).to eq([])
  end

  it "returns nothing for blank text" do
    expect(described_class.call(nil)).to eq([])
    expect(described_class.call("   ")).to eq([])
  end

  it "returns every tag when the message is ambiguous" do
    expect(described_class.call("MB napas")).to match_array(%w[mb napas])
  end

  it "ignores inactive card types" do
    CardType.find_by(key: "napas").update!(active: false)
    expect(described_class.call("Napas")).to eq([])
  end
end
