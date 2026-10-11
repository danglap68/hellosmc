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

  def rd_grid
    grid = Array.new(24) { Array.new(18) }
    grid[1][7] = "LẬP"
    grid[1][8] = "KIM"
    grid[1][9] = "AN"
    grid[1][10] = "YẾN"
    grid[1][11] = "CÔ TUYẾT"
    grid[22][6] = "Chương (MB+SP)"
    grid[22][7] = 100_000
    grid[22][8] = 50_000
    grid
  end

  def mb_grid
    [ [ "Số tiền giao dịch", "Số tiền đã khấu trừ", "Số tiền sau khi trừ phí gốc", "Tỷ lệ",
        "Lợi nhuận", "Số Lô", "Ngày giao dịch", "Giờ giao dịch", "Tên đại lý", "Tên HKD", "Người đi tiền" ] ]
  end

  def bill_grid
    [ [ "Tên Đại lý", "Số tiền sau khi trừ phí gốc", "Số tiền giao dịch", "Phí gốc", "Ngày giao dịch", "Trạng thái" ] ]
  end

  def memory(extra = {})
    Workbook::MemorySheet.new({
      "DS MB T10" => ds_mb_grid,
      "R&D Report" => rd_grid,
      "MB" => mb_grid,
      "Bill vô chủ" => bill_grid
    }.merge(extra))
  end

  def build_transaction(amount: 486_000, at: Time.zone.local(2026, 10, 1, 10, 0), rate: BigDecimal("0.0088"),
                        dealer_rate: BigDecimal("0.0121"), sender_id: 12_345, username: nil)
    message = create(:telegram_message, telegram_sender_id: sender_id, telegram_username: username)
    bill_image = create(:bill_image, telegram_message: message)
    create(:transaction, merchant: merchant, telegram_message: message, bill_image: bill_image,
           transaction_amount_vnd: amount, transaction_at: at,
           applied_base_fee_rate: rate, applied_dealer_rate: dealer_rate,
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
      expect(client.cell("R&D Report", "H23")).to eq(100_000 + 486_000)
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
      expect(client.cell("R&D Report", "I23")).to eq(50_000 + 486_000)
      expect(client.cell("R&D Report", "H23")).to eq(100_000)
    end

    it "skips R&D but still writes DS MB and MB when the remitter is unmapped" do
      client = memory
      described_class.call(transaction: build_transaction(sender_id: 999_999), client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("R&D Report", "H23")).to eq(100_000)
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

  describe "unidentified transaction" do
    it "appends a Bill vô chủ row and leaves the other sheets untouched" do
      client = memory
      allow(client).to receive(:batch_update_values).and_call_original

      transaction = build_transaction
      transaction.source_data = { "extraction" => { "merchant_name" => "KHÔNG RÕ HKD" } }
      transaction.merchant = nil
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

    it "skips transactions without a transaction date" do
      transaction = build_transaction
      transaction.update!(transaction_at: nil)
      client = memory
      expect(described_class.call(transaction: transaction, client: client, spreadsheet_id: "sheet-id"))
        .to eq(:skipped_no_date)
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
    it "duplicates the latest sheet, rewrites November dates and clears amounts" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      client = memory
      described_class.call(
        transaction: build_transaction(at: Time.zone.local(2026, 11, 1, 10, 0)),
        client: client, spreadsheet_id: "sheet-id"
      )

      expect(client.titles).to include("DS MB T11")
      expect(client.cell("DS MB T11", "A2")).to eq("2026-11-01")
      expect(client.cell("DS MB T11", "A3")).to eq("2026-11-02")
      expect(client.cell("DS MB T11", "B2")).to eq(486_000)
      expect(client.cell("DS MB T11", "B3")).to be_nil
      # T10 unchanged
      expect(client.cell("DS MB T10", "B2")).to eq(354_367_000)
    end
  end

  describe "missing fee rate" do
    it "does not crash and writes empty C/E when the rate is unknown" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      client = memory
      described_class.call(transaction: build_transaction(rate: nil), client: client, spreadsheet_id: "sheet-id")
      expect(client.cell("MB", "A2")).to eq(486_000)
      expect(client.cell("MB", "C2")).to be_nil
      expect(client.cell("MB", "E2")).to be_nil
      expect(client.cell("MB", "B2")).to eq("=A2-(A2*D2)")
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

    it "issues a session advisory lock around the write" do
      create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
      connection = Transaction.connection
      allow(connection).to receive(:execute).and_call_original
      described_class.call(transaction: build_transaction, client: memory, spreadsheet_id: "sheet-42")
      expect(connection).to have_received(:execute).with(a_string_including("pg_advisory_lock"))
      expect(connection).to have_received(:execute).with(a_string_including("pg_advisory_unlock"))
    end
  end
end
