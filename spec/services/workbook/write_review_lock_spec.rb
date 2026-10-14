require "rails_helper"

# Real connections need committed fixtures. This group cleans up only the rows
# it creates. The fake sheet's callback represents an external write in flight.
RSpec.describe "Workbook writes concurrent with review decisions" do
  self.use_transactional_tests = false

  CLEANUP_MODELS = [ AuditLog, PaperTrail::Version, WorkbookEntry, TransactionReview, Transaction,
                     RemitterTransfer, TelegramMessage, MerchantDealer, TelegramChat, Remitter, Dealer, Merchant, CardType ].freeze

  around do |example|
    prior = CLEANUP_MODELS.to_h { |model| [ model, model.pluck(:id) ] }
    example.run
  ensure
    CLEANUP_MODELS.each { |model| model.where.not(id: prior.fetch(model)).delete_all }
  end

  def concurrent_decision
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '200ms'")
        begin
          yield
        rescue ActiveRecord::LockWaitTimeout
          :locked
        ensure
          connection.execute("RESET lock_timeout")
        end
      end
    end.value
  end

  it "keeps incoming money locked until the sheet receipt is recorded" do
    record = create(:transaction, :approved, bill_image: nil, telegram_message: nil)
    decision = nil
    hook = -> do
      decision = concurrent_decision do
        Transactions::StatusUpdater.call(transaction: Transaction.find(record.id), actor: nil, action: "hold")
      end
    end
    client = Workbook::MemorySheet.new("Bill vô chủ" => [ [ "header" ] ])
    client.define_singleton_method(:batch_update_values) do |updates|
      hook.call
      super(updates)
    end

    expect(Workbook::HelloSmcWriter.call(transaction: record, client: client, spreadsheet_id: "lock-test")).to eq(:unidentified)
    expect(decision).to eq(:locked)
    expect(record.reload).to be_approved
    expect(record).to be_booked
    expect(Transactions::StatusUpdater.call(transaction: record, actor: nil, action: "hold")).to be(false)
  end

  it "keeps outgoing money locked until written_at prevents a late rejection" do
    link = create(:merchant_dealer, rd_agent_label: "Agent")
    remitter = create(:remitter, excel_key: "LAP")
    record = create(:remitter_transfer, status: "approved", amount_vnd: 1000,
                    merchant_dealer: link, merchant: link.merchant, remitter: remitter)
    decision = nil
    hook = -> do
      decision = concurrent_decision do
        RemitterTransfers::Reviewer.reject(transfer: RemitterTransfer.find(record.id), actor: nil)
      end
    end
    title = "thu chi 410"
    client = Workbook::MemorySheet.new(title => [ [ "AGENT" ], [ nil, "LAP" ], [ "Agent" ], [ nil ], [ "TOTAL", "=SUM(B3:B4)" ] ])
    client.define_singleton_method(:insert_row_with_value) do |sheet, **options|
      hook.call
      super(sheet, **options)
    end

    expect(Workbook::RemitterReportWriter.call(remitter_transfer: record, client: client, spreadsheet_id: "lock-test")).to eq(:written)
    expect(decision).to eq(:locked)
    expect(record.reload).to be_written
    expect(record).to be_approved
    result = RemitterTransfers::Reviewer.reject(transfer: record, actor: nil)
    expect(result).not_to be_ok
    expect(result.errors).to include(:already_written)
  end
end
