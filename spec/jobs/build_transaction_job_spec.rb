require "rails_helper"

RSpec.describe BuildTransactionJob do
  include_context "accounting setup"

  it "builds transactions for an analyzed bill image" do
    bill_image = analyzed_bill
    expect { described_class.perform_now(bill_image.id) }.to change(Transaction, :count).by(1)
    expect(Transaction.last).to be_approved
  end

  it "is safe to run twice" do
    bill_image = analyzed_bill
    described_class.perform_now(bill_image.id)
    expect { described_class.perform_now(bill_image.id) }.not_to change(Transaction, :count)
  end

  it "discards jobs for deleted images" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
