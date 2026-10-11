require "rails_helper"
require "rake"
require "sidekiq/api"

RSpec.describe "hellosmc:purge_transaction_data" do
  include_context "accounting setup"

  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "hellosmc:purge_transaction_data" } }

  let(:task) { Rake::Task["hellosmc:purge_transaction_data"] }
  let(:queue) { instance_double(Sidekiq::Queue, size: 0, clear: true) }
  let(:retries) { instance_double(Sidekiq::RetrySet, size: 0, clear: true) }
  let(:scheduled) { instance_double(Sidekiq::ScheduledSet, size: 0, clear: true) }

  before do
    allow(Sidekiq::Queue).to receive(:all).and_return([ queue ])
    allow(Sidekiq::RetrySet).to receive(:new).and_return(retries)
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return(scheduled)
    remitter
    bill_image = analyzed_bill
    Transactions::Builder.call(bill_image: bill_image)
    AuditLogger.log!(action: "settings.updated", metadata: { "note" => "kept" })
  end

  after { task.reenable }

  let(:remitter) { create(:remitter) }

  def run(confirm:)
    previous = ENV["CONFIRM"]
    ENV["CONFIRM"] = confirm
    expect { task.invoke }.to output.to_stdout
  ensure
    ENV["CONFIRM"] = previous
  end

  it "deletes nothing without CONFIRM=yes" do
    expect { run(confirm: nil) }.not_to change(Transaction, :count)
    expect(BillImage.count).to eq(1)
    expect(queue).not_to have_received(:clear)
  end

  it "deletes transaction data and keeps configuration" do
    expect(Transaction.count).to eq(1)

    run(confirm: "yes")

    expect([ Transaction, TransactionReview, WorkbookEntry, BillImage, BillAlbum, TelegramMessage, ExcelExport ].map(&:count))
      .to all(eq(0))
    expect(ActiveStorage::Attachment.where(record_type: "BillImage")).to be_empty
    expect(AuditLog.where(auditable_type: "Transaction")).to be_empty
    expect(AuditLog.where(action: "settings.updated")).to exist
    expect([ CardType, Dealer, Merchant, MerchantDealer, FeeRule, Remitter, TelegramChat ].map(&:count)).to all(be_positive)
    expect(queue).to have_received(:clear)
    expect(retries).to have_received(:clear)
    expect(scheduled).to have_received(:clear)
  end
end
