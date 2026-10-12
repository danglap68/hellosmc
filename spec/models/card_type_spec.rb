require "rails_helper"

RSpec.describe CardType do
  it "makes the code from the name and puts a new card type last (K1)" do
    create(:card_type, key: "mb", position: 4)

    card_type = described_class.create!(name: "Thẻ Visa")

    expect(card_type.key).to eq("the_visa")
    expect(card_type.position).to eq(5)
  end

  it "never blocks on a code already taken" do
    create(:card_type, key: "the_visa", name: "Visa cũ")

    expect(described_class.create!(name: "Thẻ Visa").key).to eq("the_visa_2")
  end

  it "keeps a code given by hand" do
    expect(described_class.create!(key: "napas", name: "Napas").key).to eq("napas")
  end
end
