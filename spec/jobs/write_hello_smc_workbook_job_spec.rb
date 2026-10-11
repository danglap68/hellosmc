require "rails_helper"

RSpec.describe WriteHelloSmcWorkbookJob do
  let(:transaction) { create(:transaction, :approved) }

  it "calls the workbook writer with the transaction" do
    expect(Workbook::HelloSmcWriter).to receive(:call).with(transaction:).and_return(:identified)
    described_class.perform_now(transaction.id)
  end

  it "discards without retry when the spreadsheet id is missing and leaves the transaction intact" do
    allow(AppConfig).to receive(:hello_smc_spreadsheet_id).and_return(nil)
    expect(StructuredLog).to receive(:error).with("workbook.hello_smc_configuration_error", error: anything)
    expect {
      described_class.perform_now(transaction.id)
    }.not_to raise_error
    expect(WorkbookEntry.count).to eq(0)
    expect(Transaction.find(transaction.id)).to be_present
  end

  it "retries later when another writer holds the spreadsheet lock" do
    allow(Workbook::HelloSmcWriter).to receive(:call).and_raise(Workbook::HelloSmcWriter::LockBusy)
    expect { described_class.perform_now(transaction.id) }
      .to have_enqueued_job(described_class).with(transaction.id)
  end

  it "discards the job when the transaction no longer exists" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
