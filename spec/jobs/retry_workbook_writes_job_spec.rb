require "rails_helper"

RSpec.describe RetryWorkbookWritesJob do
  include ActiveJob::TestHelper

  before { allow(AppConfig).to receive(:hello_smc_spreadsheet_id).and_return("sheet-id") }

  def stale(transaction)
    transaction.update_columns(updated_at: 1.hour.ago)
    transaction
  end

  def finalized(status: "approved", **attrs)
    traits = status.in?(Transaction::FINALIZED_STATUSES) ? [ :calculated ] : []
    create(:transaction, *traits, status: status, transaction_amount_vnd: 1_000_000,
           transaction_at: Time.zone.local(2026, 10, 1, 10), **attrs)
  end

  it "re-enqueues approved transactions that never reached the sheet" do
    missing = stale(finalized)
    exported = stale(finalized(status: "exported"))

    expect { described_class.perform_now }
      .to have_enqueued_job(WriteHelloSmcWorkbookJob).with(missing.id)
      .and have_enqueued_job(WriteHelloSmcWorkbookJob).with(exported.id)
  end

  it "skips transactions already written, still in grace, or not finalized" do
    written = stale(finalized)
    WorkbookEntry.create!(recorded_transaction: written, spreadsheet_id: "sheet-id", amount_vnd: 1, branch: "identified")
    fresh = finalized
    review = stale(finalized(status: "needs_review"))

    expect { described_class.perform_now }.not_to have_enqueued_job(WriteHelloSmcWorkbookJob)
    expect(fresh.reload.updated_at).to be > 15.minutes.ago
  end

  it "does nothing when the spreadsheet is not configured" do
    stale(finalized)
    allow(AppConfig).to receive(:hello_smc_spreadsheet_id).and_return(nil)
    expect { described_class.perform_now }.not_to have_enqueued_job(WriteHelloSmcWorkbookJob)
  end
end
