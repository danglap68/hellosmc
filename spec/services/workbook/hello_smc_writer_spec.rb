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

  def bill_grid
    [ [ "Tên Đại lý", "Số tiền sau khi trừ phí gốc", "Số tiền giao dịch", "Phí gốc", "Ngày giao dịch", "Trạng thái" ] ]
  end

  def memory(extra = {}, row_limits = {})
    Workbook::MemorySheet.new({
      "DS MB T10" => ds_mb_grid,
      "MB" => mb_grid,
      "Bill vô chủ" => bill_grid
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

    it "books the bill in Bill vô chủ when the day cell holds text it cannot add to" do
      client = write_with("ghi chú")

      expect(client.cell("DS MB T10", "B2")).to eq("ghi chú")
      expect(client.cell("MB", "A2")).to be_nil
      expect(client.cell("Bill vô chủ", "C2")).to eq(486_000)
      expect(WorkbookEntry.last.branch).to eq("unidentified")
      expect(WorkbookEntry.last.payload["issue"]).to eq("ds_cell_not_numeric")
    end

    it "does not add to a formula that is not a plain running sum" do
      client = write_with("=SUM(C2:D2)")

      expect(client.cell("DS MB T10", "B2")).to eq("=SUM(C2:D2)")
      expect(WorkbookEntry.last.payload["issue"]).to eq("ds_cell_not_numeric")
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

  describe "unidentified transaction" do
    it "appends a Bill vô chủ row and leaves the other sheets untouched" do
      client = memory
      allow(client).to receive(:batch_update_values).and_call_original

      transaction = build_transaction
      transaction.source_data = { "extraction" => { "merchant_name" => "KHÔNG RÕ HKD" } }
      transaction.save!

      result = described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")

      expect(result).to eq(:unidentified)
      expect(client.cell("Bill vô chủ", "C2")).to eq(486_000)
      expect(client.cell("Bill vô chủ", "A2")).to eq("KHÔNG RÕ HKD")
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
      expect(client).to have_received(:batch_update_values).once
      expect(WorkbookEntry.count).to eq(1)
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

    it "does not add a second Bill vô chủ row on retry" do
      client = memory
      transaction = build_transaction
      transaction.source_data = { "extraction" => { "merchant_name" => "KHÔNG RÕ HKD" } }
      transaction.save!
      calls = 0
      allow(WorkbookEntry).to receive(:create!).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::StatementInvalid, "db down" if calls == 1

        original.call(*args)
      end

      expect { described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id") }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id"))
        .to eq(:already_written)
      expect(client.cell("Bill vô chủ", "A3")).to be_nil
      expect(WorkbookEntry.count).to eq(1)
    end

    it "writes OCR text that looks like a formula as literal text" do
      client = memory
      sent = nil
      allow(client).to receive(:batch_update_values).and_wrap_original do |original, updates|
        sent = updates
        original.call(updates)
      end
      transaction = build_transaction
      transaction.source_data = { "extraction" => { "merchant_name" => "=IMPORTXML(\"http://evil.example\",\"//a\")" } }
      transaction.save!

      described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")

      expect(sent.first[:rows].first.first).to start_with("'=IMPORTXML")
      expect(client.cell("Bill vô chủ", "A2")).to start_with("=IMPORTXML")
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

      expect(result).to eq(:unidentified)
      expect(WorkbookEntry.last.payload["issue"]).to eq("ds_cell_missing")
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
