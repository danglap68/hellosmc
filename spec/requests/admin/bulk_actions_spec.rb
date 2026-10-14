require "rails_helper"

RSpec.describe "Admin bulk actions" do
  include_context "accounting setup"
  let(:admin) { create(:user, :admin) }
  let(:operator) { create(:user, :operator) }

  before { sign_in admin }

  def run_bulk(resource, operation, records, **overrides)
    post admin_bulk_actions_path, params: {
      resource: resource, operation: operation, ids: records.map(&:id),
      versions: records.to_h { |record| [ record.id.to_s, BulkActions::Catalog.version(record) ] }
    }.merge(overrides), as: :json
  end

  def outcomes = response.parsed_body.fetch("results")

  it "authenticates and enforces manage permission on the requested resource" do
    row = create(:transaction)
    sign_out admin
    run_bulk("transactions", "hold", [ row ])
    expect(response).to have_http_status(:unauthorized)
    sign_in create(:user, :viewer)
    run_bulk("transactions", "hold", [ row ])
    expect(response).to have_http_status(:forbidden)
    expect(row.reload).to be_needs_review
    sign_in operator
    run_bulk("dealers", "deactivate", [ dealer ])
    expect(response).to have_http_status(:forbidden)
    expect(dealer.reload).to be_active
  end

  it "keeps review permission separate from transaction management" do
    row = create(:transaction)
    sign_in create(:user, role: "doi_soat")
    run_bulk("transactions", "hold", [ row ])
    expect(response).to have_http_status(:forbidden)
    run_bulk("reviews", "hold", [ row ])
    expect(response).to be_successful
    expect(row.reload).to be_hold
  end

  it "reports successful, invalid, stale and missing rows individually without touching unselected rows" do
    eligible = create(:transaction)
    finalized = create(:transaction, :approved)
    stale = create(:transaction)
    untouched = create(:transaction)
    missing = create(:transaction)
    versions = [ eligible, finalized, stale, missing ].to_h { |row| [ row.id.to_s, BulkActions::Catalog.version(row) ] }
    stale.update!(lot_number: "999999")
    missing.destroy!
    run_bulk("transactions", "reject", [ eligible, finalized, stale, missing ], versions: versions, note: "Trùng bill")
    expect(response).to be_successful
    expect(outcomes.map { |row| row["success"] }).to eq([ true, false, false, false ])
    expect(eligible.reload).to be_rejected
    expect(eligible.reviews.last.note).to eq("Trùng bill")
    expect(finalized.reload).to be_approved
    expect(stale.reload).to be_needs_review
    expect(untouched.reload).to be_needs_review
    expect(outcomes[2]["message"]).to eq(I18n.t("flash.stale"))
    expect(outcomes[3]["message"]).to eq(I18n.t("bulk.missing"))
  end

  it "refuses an invalid selection or operation before changing any row" do
    row = create(:transaction)
    [ { ids: [] }, { ids: [ row.id, row.id ] }, { ids: [ "1 OR 1=1" ] },
      { versions: {} }, { ids: Array.new(101) { |index| index + 1 } }, { operation: "destroy" } ].each do |overrides|
      run_bulk("transactions", "hold", [ row ], **overrides)
      expect(response).to have_http_status(:unprocessable_content)
      expect(row.reload).to be_needs_review
    end
  end

  it "requires an editable reason for every bulk rejection" do
    row = create(:transaction)
    run_bulk("transactions", "reject", [ row ], note: " \n ")
    expect(response).to have_http_status(:unprocessable_content)
    expect(row.reload).to be_needs_review
    expect(AuditLog.where(auditable: row)).to be_empty
  end

  it "uses normal approval calculations, actor audit and queues writes only for approved rows" do
    valid = Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole
    invalid = create(:transaction, transaction_amount_vnd: nil)
    sign_in operator
    run_bulk("transactions", "approve", [ valid, invalid ])
    expect(outcomes.map { |row| row["success"] }).to eq([ true, false ])
    expect(valid.reload).to be_approved
    expect(valid.approved_by).to eq(operator)
    expect(valid.amount_after_base_fee_vnd).to eq(11_344_284)
    expect(invalid.reload).to be_needs_review
    expect(WriteHelloSmcWorkbookJob).to have_been_enqueued.with(valid.id)
    expect(WriteHelloSmcWorkbookJob).not_to have_been_enqueued.with(invalid.id)
  end

  it "does not persist failed approval's intermediate status transition" do
    row = create(:transaction, status: "failed", transaction_amount_vnd: nil)
    run_bulk("transactions", "approve", [ row ])
    expect(outcomes.first["success"]).to be(false)
    expect(row.reload).to be_failed
    expect(AuditLog.where(auditable: row, action: "transaction.approved")).to be_empty
  end

  it "reprocesses multiple settlements on one image with only one queued OCR run" do
    image = create(:bill_image, :analyzed)
    rows = create_list(:transaction, 2, bill_image: image)
    run_bulk("transactions", "reprocess", rows)
    expect(outcomes.map { |row| row["success"] }).to eq([ true, true ])
    expect(rows.map { |row| row.reload.status }).to eq(%w[processing processing])
    expect(AnalyzeBillImageJob).to have_been_enqueued.with(image.id, force: true).exactly(:once)
  end

  it "does not enqueue an approval write when an enclosing transaction rolls back" do
    row = Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole
    Transaction.transaction(requires_new: true) do
      expect(Transactions::Approver.call(transaction: row, actor: admin)).to be(true)
      raise ActiveRecord::Rollback
    end
    expect(row.reload).to be_needs_review
    expect(WriteHelloSmcWorkbookJob).not_to have_been_enqueued.with(row.id)
  end

  it "keeps deletion callbacks and reports referenced records while deleting eligible ones" do
    unused = create(:dealer)
    run_bulk("dealers", "destroy", [ dealer, unused ])
    expect(outcomes.map { |row| row["success"] }).to eq([ false, true ])
    expect(Dealer.exists?(dealer.id)).to be(true)
    expect(Dealer.exists?(unused.id)).to be(false)
    expect(AuditLog.find_by!(auditable_type: "Dealer", auditable_id: unused.id).actor_user).to eq(admin)
  end

  it "updates configuration through validations and audits and refuses a stale timestamp" do
    version = BulkActions::Catalog.version(dealer)
    dealer.update!(name: "Đại lý vừa sửa", updated_at: 1.second.from_now)
    run_bulk("dealers", "deactivate", [ dealer ], versions: { dealer.id.to_s => version })
    expect(outcomes.first["success"]).to be(false)
    run_bulk("dealers", "deactivate", [ dealer ])
    expect(outcomes.first["success"]).to be(true)
    expect(dealer.reload).not_to be_active
    expect(AuditLog.where(auditable: dealer, action: "dealer.updated").last.metadata["bulk"]).to be(true)
  end

  it "does not let the current administrator deactivate or delete their own account" do
    %w[deactivate destroy].each do |operation|
      run_bulk("users", operation, [ admin ])
      expect(outcomes.first["success"]).to be(false)
      expect(admin.reload).to be_active
    end
  end

  it "clears transfer codes without destroying the merchant/dealer association" do
    merchant_dealer_link.update!(transfer_code: "TK01")
    run_bulk("transfer_codes", "destroy", [ merchant_dealer_link ])
    expect(outcomes.first["success"]).to be(true)
    expect(merchant_dealer_link.reload.transfer_code).to be_nil
    expect(merchant_dealer_link.merchant).to eq(merchant)
    expect(merchant_dealer_link.dealer).to eq(dealer)
  end

  it "processes only stored images from active groups and does not queue them twice" do
    message = create(:telegram_message, telegram_chat: chat, processing_status: "ignored")
    inactive = create(:telegram_chat, active: false)
    run_bulk("telegram_chats", "process_stored", [ chat, inactive ])
    expect(outcomes.map { |row| row["success"] }).to eq([ true, false ])
    expect(message.reload).to be_processing_queued
    expect(DownloadTelegramAttachmentJob).to have_been_enqueued.with(message.id).exactly(:once)
    run_bulk("telegram_chats", "process_stored", [ chat ])
    expect(DownloadTelegramAttachmentJob).to have_been_enqueued.with(message.id).exactly(:once)
  end

  it "retries outgoing transfers through the existing bounded retry policy" do
    image = create(:bill_image, :analyzed, extraction: "transfer")
    retryable = create(:remitter_transfer, bill_image: image, telegram_message: image.telegram_message,
                                         status: "needs_review", amount_vnd: 100_000, review_reasons: [ "code_missing" ])
    written = create(:remitter_transfer, status: "approved", amount_vnd: 100_000, written_at: Time.current)
    sign_in operator
    run_bulk("remitter_transfers", "retry", [ retryable, written ])
    expect(outcomes.map { |row| row["success"] }).to eq([ true, false ])
    expect(retryable.reload).to be_processing
    expect(written.reload).to be_approved
    expect(BuildRemitterTransferJob).to have_been_enqueued.with(retryable.id)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "requires a reviewable outgoing transfer and preserves human rejection and written transfers" do
    merchant_dealer_link.update!(transfer_code: "TK01")
    valid = create(:remitter_transfer, status: "needs_review", transfer_code: "tk 001", amount_vnd: 100_000)
    rejected = create(:remitter_transfer, status: "rejected", reviewed_by: admin, amount_vnd: 100_000)
    run_bulk("remitter_transfers", "approve", [ valid, rejected ])
    expect(outcomes.map { |row| row["success"] }).to eq([ true, false ])
    expect(valid.reload).to be_approved
    expect(valid.transfer_code).to eq("TK01")
    expect(WriteRemitterReportJob).to have_been_enqueued.with(valid.id)
    expect(rejected.reload).to be_rejected
  end

  it "queues outgoing sheet writes only for complete, approved and unwritten rows" do
    writable = create(:remitter_transfer, status: "approved", amount_vnd: 100_000, merchant_dealer: merchant_dealer_link)
    written = create(:remitter_transfer, status: "approved", amount_vnd: 100_000, merchant_dealer: merchant_dealer_link, written_at: Time.current)
    run_bulk("remitter_transfers", "write", [ writable, written ])
    expect(outcomes.map { |row| row["success"] }).to eq([ true, false ])
    expect(WriteRemitterReportJob).to have_been_enqueued.with(writable.id).exactly(:once)
    expect(WriteRemitterReportJob).not_to have_been_enqueued.with(written.id)
  end

  it "renders versioned selectable rows and hides mutation actions from read-only users" do
    row = create(:transaction, source_data: { "possible_duplicate_ids" => [ 120 ] })
    get admin_transactions_path
    page = Nokogiri::HTML(response.body)
    table = page.at_css('table[data-controller="bulk-table"]')
    expect(JSON.parse(table["data-bulk-table-operations-value"]).pluck("key")).to include("approve", "reject")
    expect(table.at_css("tr[data-bulk-id='#{row.id}']")["data-bulk-reason"]).to eq("Trùng với giao dịch #120")
    expect(table.at_css("tr[data-bulk-id='#{row.id}']")["data-bulk-version"]).to eq(row.lock_version.to_s)
    expect(page.at_css("#bulk-table-toolbar")).to be_present
    sign_in create(:user, :viewer)
    get admin_transactions_path
    table = Nokogiri::HTML(response.body).at_css('table[data-controller="bulk-table"]')
    expect(JSON.parse(table["data-bulk-table-operations-value"])).to be_empty
  end
end
