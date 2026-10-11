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

  # Same shape as a real "thu chi" tab: row 2 repeats the remitter names per
  # block, each agent has a label row, entry rows, a spacer and a TOTAL row.
  # Blocks: A–F (Thọ), G–L (Chương); then Lập and An, whose names also appear
  # in the remitter header; then the manual bottom area.
  def rd_grid
    grid = Array.new(16) { Array.new(14) }
    grid[0][1] = "RIMITTER"
    grid[0][6] = "AGENT"
    grid[0][7] = "RIMITTER"
    [ 1, 7 ].each { |start| [ "LẬP", "KIM", "AN", "YẾN", "CÔ TUYẾT" ].each_with_index { |name, i| grid[1][start + i] = name } }
    grid[2][0] = "Thọ\n(MB)"
    grid[2][1] = 32_000_000
    grid[3][1] = 5_000_000
    grid[2][6] = "Chương\n(MB+SP)"
    grid[6][0] = "TOTAL"
    grid[6][6] = "TOTAL"
    grid[8][6] = "Lập \n(MB+SP+QR)"
    grid[10][6] = "TOTAL"
    grid[9][0] = "An (QR)"
    grid[11][0] = "TOTAL"
    grid[13][13] = "TOTAL AMOUNT (IN)"
    grid[14][0] = "SP in"
    grid[14][1] = 143_494_999
    grid
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
      "thu chi 110" => rd_grid,
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
    it "writes DS MB, R&D and MB in a single batch and records the entry" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      client = memory
      allow(client).to receive(:batch_update_values).and_call_original

      result = described_class.call(transaction: build_transaction, client: client, spreadsheet_id: "sheet-id")

      expect(result).to eq(:identified)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000 + 486_000)
      expect(client.cell("thu chi 110", "H3")).to eq(486_000)
      expect(client.cell("MB", "A2")).to eq(486_000)
      expect(client.cell("MB", "I2")).to eq("Chương")
      expect(client.cell("MB", "J2")).to eq("001_ HỘ KINH DOANH THIÊN KIM GV")
      expect(client.cell("MB", "K2")).to eq("Lập")
      expect(client).to have_received(:batch_update_values).once
      expect(WorkbookEntry.count).to eq(1)
    end

    it "uses the day's row and leaves other days untouched" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      client = memory
      described_class.call(transaction: build_transaction(at: Time.zone.local(2026, 10, 2, 10, 0)),
                           client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("DS MB T10", "B3")).to eq(101_068_000 + 486_000)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
    end

    it "uses the right R&D column for a different remitter" do
      create(:remitter, name: "Kim", excel_key: "KIM", telegram_user_id: 99)
      client = memory
      described_class.call(transaction: build_transaction(sender_id: 99), client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("thu chi 110", "I3")).to eq(486_000)
      expect(client.cell("thu chi 110", "H3")).to be_nil
    end

    it "skips R&D but still writes DS MB and MB when the remitter is unmapped" do
      client = memory
      described_class.call(transaction: build_transaction(sender_id: 999_999), client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("thu chi 110", "H3")).to be_nil
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000 + 486_000)
      expect(client.cell("MB", "A2")).to eq(486_000)
      expect(client.cell("MB", "K2")).to be_nil
    end

    it "writes the agent name, not the fee dealer, to MB column I" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      fee_dealer = create(:dealer, name: "Anh Trân")
      client = memory
      described_class.call(transaction: build_transaction.tap { |t| t.update!(dealer: fee_dealer) },
                           client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("MB", "I2")).to eq("Chương")
    end
  end

  describe "remitter report (thu chi tab)" do
    let!(:lap) { create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345) }

    def write(client, **opts)
      described_class.call(transaction: build_transaction(**opts), client: client, spreadsheet_id: "sheet-id")
    end

    it "appends to the first free cell of the remitter column, never accumulating into one cell" do
      client = memory
      write(client)
      write(client, amount: 100_000)
      expect(client.cell("thu chi 110", "H3")).to eq(486_000)
      expect(client.cell("thu chi 110", "H4")).to eq(100_000)
    end

    it "skips filled cells in the block" do
      client = memory("thu chi 110" => rd_grid.tap { |g| g[2][7] = 1; g[3][7] = 2 })
      write(client)
      expect(client.cell("thu chi 110", "H5")).to eq(486_000)
    end

    it "uses the tab of the transaction's own day" do
      client = memory("thu chi 210" => rd_grid)
      write(client, at: Time.zone.local(2026, 10, 2, 10, 0))
      expect(client.cell("thu chi 210", "H3")).to eq(486_000)
      expect(client.cell("thu chi 110", "H3")).to be_nil
    end

    it "does not zero-pad the day or month in the tab name" do
      client = memory("thu chi 910" => rd_grid,
                      "DS MB T10" => [[ "Thiên Kim GV", "Chương (tid1)" ], [ Date.new(2026, 10, 9), 0 ]])
      write(client, at: Time.zone.local(2026, 10, 9, 10, 0))
      expect(client.cell("thu chi 910", "H3")).to eq(486_000)
    end

    it "records the tab and cell on the workbook entry" do
      write(memory)
      entry = WorkbookEntry.last
      expect(entry.rd_cell).to eq("H3")
      expect(entry.payload).to include("rd_sheet" => "thu chi 110")
    end

    it "skips only the report when the day's tab does not exist" do
      client = memory
      client.delete_sheet("thu chi 110")
      write(client)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000 + 486_000)
      expect(client.cell("MB", "A2")).to eq(486_000)
      expect(WorkbookEntry.last.payload).to include("issue" => "rd_sheet_missing")
      expect(WorkbookEntry.last.rd_cell).to be_nil
    end

    it "reports rd_block_full instead of writing outside the block" do
      client = memory("thu chi 110" => rd_grid.tap { |g| (2..5).each { |r| g[r][7] = 1 } })
      write(client)
      expect(client.cell("thu chi 110", "H7")).to be_nil
      expect(WorkbookEntry.last.payload).to include("issue" => "rd_block_full")
      expect(client.cell("MB", "A2")).to eq(486_000)
    end

    it "reports rd_agent_missing when no block carries the agent label" do
      link.update!(rd_agent_label: "Không có")
      write(memory)
      expect(WorkbookEntry.last.payload).to include("issue" => "rd_agent_missing")
    end

    it "inserts a column in every block when the remitter is new, then writes into it" do
      create(:remitter, name: "Trí", excel_key: "TRÍ", telegram_user_id: 77)
      grid = rd_grid
      grid[6][5] = "=SUM(F3:F6)"
      client = memory("thu chi 110" => grid)
      write(client, sender_id: 77)

      header = client.sheets["thu chi 110"][1]
      expect(header.count("TRÍ")).to eq(2)
      expect(header.first(8)).to eq([ nil, "LẬP", "KIM", "AN", "YẾN", "CÔ TUYẾT", "TRÍ", nil ])
      expect(client.cell("thu chi 110", "G7")).to eq("=SUM(G3:G6)")
      expect(client.cell("thu chi 110", "H3")).to eq("Chương\n(MB+SP)")
      expect(client.cell("thu chi 110", "N3")).to eq(486_000)
      expect(WorkbookEntry.last.rd_cell).to eq("N3")
      expect(WorkbookEntry.last.payload["issue"]).to be_nil
    end

    it "leaves the manual accounting area below the blocks in place" do
      create(:remitter, name: "Trí", excel_key: "TRÍ", telegram_user_id: 77)
      client = memory
      write(client, sender_id: 77)
      expect(client.cell("thu chi 110", "A15")).to eq("SP in")
      expect(client.cell("thu chi 110", "B15")).to eq(143_494_999)
      expect(client.cell("thu chi 110", "N14")).to eq("TOTAL AMOUNT (IN)")
    end

    it "does not insert again on a later transaction of the same remitter" do
      create(:remitter, name: "Trí", excel_key: "TRÍ", telegram_user_id: 77)
      client = memory
      write(client, sender_id: 77)
      write(client, sender_id: 77, amount: 100_000)
      expect(client.sheets["thu chi 110"][1].count("TRÍ")).to eq(2)
      expect(client.cell("thu chi 110", "N4")).to eq(100_000)
    end

    it "does not insert columns when the agent is not found" do
      create(:remitter, name: "Trí", excel_key: "TRÍ", telegram_user_id: 77)
      link.update!(rd_agent_label: "Không có")
      client = memory
      write(client, sender_id: 77)
      expect(client.sheets["thu chi 110"][1]).not_to include("TRÍ")
      expect(WorkbookEntry.last.payload["issue"]).to eq("rd_agent_missing")
    end

    it "does not confuse an agent named like a remitter with the header" do
      link.update!(rd_agent_label: "Lập")
      client = memory
      write(client)
      expect(client.cell("thu chi 110", "H9")).to eq(486_000)
      expect(client.cell("thu chi 110", "H2")).to eq("LẬP")
    end

    it "matches labels with a trailing channel and no parentheses" do
      link.update!(rd_agent_label: "An")
      client = memory
      write(client)
      expect(client.cell("thu chi 110", "B10")).to eq(486_000)
    end

    it "never reads the manual accounting area below the blocks" do
      link.update!(rd_agent_label: "SP in")
      write(memory)
      expect(WorkbookEntry.last.payload).to include("issue" => "rd_agent_missing")
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
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      transaction = build_transaction
      client = memory
      described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")
      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id"))
        .to eq(:already_written)
      expect(WorkbookEntry.count).to eq(1)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000 + 486_000)
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
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      expect { described_class.call(transaction: build_transaction, client: memory, spreadsheet_id: nil) }
        .to raise_error(Workbook::HelloSmcWriter::ConfigurationError)
    end
  end

  describe "month rollover" do
    let(:november) { Time.zone.local(2026, 11, 3, 10, 0) }

    before { create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345) }

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
      expect(client.cell("DS MB T11", "B4")).to eq(486_000)
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
      expect(client.cell("DS MB T11", "B2")).to eq(486_000)
      expect(WorkbookEntry.count).to eq(1)
    end

    it "keeps day 31 available when December is cloned from a 30-day November" do
      client = memory("DS MB T10" => october_grid)
      described_class.call(transaction: build_transaction(at: november), client: client, spreadsheet_id: "sheet-id")
      described_class.call(transaction: build_transaction(at: Time.zone.local(2026, 12, 31, 10, 0)),
                           client: client, spreadsheet_id: "sheet-id")

      expect(client.cell("DS MB T12", "A32")).to eq(Date.new(2026, 12, 31))
      expect(client.cell("DS MB T12", "B32")).to eq(486_000)
    end
  end

  describe "ledger rows" do
    before { create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345) }

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
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000 + 486_000)

      result = described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id")

      expect(result).to eq(:already_written)
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000 + 486_000)
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
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
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
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      client = memory
      described_class.call(transaction: build_transaction(amount: 100_000), client: client, spreadsheet_id: "sheet-id")
      described_class.call(transaction: build_transaction(amount: 200_000), client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000 + 100_000 + 200_000)
    end

    it "takes a session advisory lock around the write" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      transaction = build_transaction
      connection = Transaction.connection
      allow(connection).to receive(:select_value).and_call_original
      allow(connection).to receive(:execute).and_call_original
      described_class.call(transaction: transaction, client: memory, spreadsheet_id: "sheet-42")
      expect(connection).to have_received(:select_value).with(a_string_including("pg_try_advisory_lock"))
      expect(connection).to have_received(:execute).with(a_string_including("pg_advisory_unlock"))
    end

    it "raises LockBusy without writing when another writer holds the lock" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
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
