require "rails_helper"

RSpec.describe RemitterTransfers::DuplicateDetector do
  let(:remitter) { create(:remitter) }
  let(:transfer) do
    create(:remitter_transfer, remitter: remitter, amount_vnd: 14_815_636, transfer_code: "CH1",
                              transferred_at: Time.current)
  end

  def matching_transfer(**attributes)
    create(:remitter_transfer, remitter: remitter, amount_vnd: transfer.amount_vnd, transfer_code: "CH01",
                              transferred_at: transfer.transferred_at - 9.seconds, status: "approved", **attributes)
  end

  it "names the matching transfer and recognizes equivalent zero-padded codes" do
    original = matching_transfer
    result = described_class.call(transfer: transfer)
    expect(result).to be_possible_duplicate
    expect(result.matches.map { |match| [ match.transfer.id, match.reasons ] })
      .to eq([ [ original.id, [ "same_payment_details" ] ] ])
    expect(result.snapshot["matches"]).to eq([ { "id" => original.id, "reasons" => [ "same_payment_details" ] } ])
  end

  it "excludes unrelated, rejected, failed and out-of-window payments and the current row" do
    matching_transfer(status: "rejected")
    matching_transfer(status: "failed")
    matching_transfer(amount_vnd: 1)
    matching_transfer(remitter: create(:remitter))
    matching_transfer(transfer_code: "CH10")
    matching_transfer(transferred_at: transfer.transferred_at - AppConfig.duplicate_window_minutes.minutes - 1.second)
    expect(described_class.call(transfer: transfer)).not_to be_possible_duplicate
  end

  it "names the original photo's transfer even outside the payment matching window" do
    original = matching_transfer(transferred_at: 1.day.ago, status: "rejected")
    original_image = create(:bill_image, telegram_message: original.telegram_message)
    duplicate_image = create(:bill_image, telegram_message: transfer.telegram_message, duplicate_of: original_image,
                                          ocr_status: "duplicate")
    transfer.update!(bill_image: duplicate_image)
    result = described_class.call(transfer: transfer)
    expect(result.original_image).to eq(original_image)
    expect(result.matches.sole.transfer).to eq(original)
    expect(result.matches.sole.reasons).to eq([ "same_image" ])
  end

  it "keeps the original photo as evidence when there is no original transfer" do
    original_image = create(:bill_image)
    image = create(:bill_image, telegram_message: transfer.telegram_message, duplicate_of: original_image,
                               ocr_status: "duplicate")
    transfer.update!(bill_image: image)
    result = described_class.call(transfer: transfer)
    expect(result).to be_possible_duplicate
    expect(result.matches).to be_empty
    expect(result.original_image).to eq(original_image)
  end

  it "combines image and payment reasons into one matching row" do
    original = matching_transfer
    original_image = create(:bill_image, telegram_message: original.telegram_message)
    image = create(:bill_image, telegram_message: transfer.telegram_message, duplicate_of: original_image,
                               ocr_status: "duplicate")
    transfer.update!(bill_image: image)
    result = described_class.call(transfer: transfer)
    expect(result.matches.sole.reasons).to eq(%w[same_image same_payment_details])
  end

  it "retains recorded evidence for review after the other transfer's status changes" do
    original = matching_transfer
    transfer.update!(metadata: { "duplicate_check" => described_class.call(transfer: transfer).snapshot })
    original.update!(status: "rejected")
    expect(described_class.call(transfer: transfer)).not_to be_possible_duplicate
    result = described_class.call(transfer: transfer, include_recorded: true)
    expect(result.matches.sole.transfer).to eq(original)
    expect(result.matches.sole.reasons).to eq([ "same_payment_details" ])
  end
end
