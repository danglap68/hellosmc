require "rails_helper"

RSpec.describe Workbook::RemitterReportWriter do
  let(:merchant) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }
  let(:chuong) { create(:dealer, name: "Chương") }
  let(:link) do
    create(:merchant_dealer, merchant: merchant, dealer: chuong, tid_key: "tid1",
           ds_sheet_anchor: "Thiên Kim GV", ds_header: "Chương (tid1)", rd_agent_label: "Chương")
  end
  let(:lap) { create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 777) }

  def remitters_1010 = [ "LẬP", "KIM", "AN", "YẾN", "CÔ TUYẾT", "DUC", "LOI" ]

  # Same shape as the live "thu chi 1010" tab: two blocks side by side
  # (A: CườngDuyen, I: Chương), labels on row 23, TOTAL on row 32, then the
  # manual cash book. With LOI the Chương/LẬP column is J.
  def tab(remitters: remitters_1010, label_row: 22, total_row: 31, total_formula: nil)
    width = (remitters.size + 1) * 2
    grid = Array.new(42) { Array.new(width) }
    [ 0, remitters.size + 1 ].each do |block_col|
      grid[0][block_col] = "AGENT"
      remitters.each_with_index { |name, i| grid[1][block_col + 1 + i] = name }
      grid[total_row][block_col] = "TOTAL"
      remitters.each_index do |i|
        letter = (65 + block_col + 1 + i).chr
        grid[total_row][block_col + 1 + i] = total_formula&.call(letter) || "=SUM(#{letter}#{label_row + 1}:#{letter}#{total_row})"
      end
    end
    grid[label_row][0] = "CườngDuyen\n(MB+SP)"
    grid[label_row][remitters.size + 1] = "Chương\n(MB+SP)"
    grid[label_row][remitters.size + 2] = 18_109_862
    grid[40][0] = "SP in"
    grid
  end

  def memory(title = "thu chi 1010", grid = tab)
    Workbook::MemorySheet.new({ title => grid })
  end

  def transfer(amount: 29_274_000, at: Time.zone.local(2026, 10, 10, 20, 36), **attrs)
    create(:remitter_transfer, remitter: lap, merchant: merchant, merchant_dealer: link, transfer_code: "TK01",
                               status: "approved", amount_vnd: amount, transferred_at: at, **attrs)
  end

  def write(record, client)
    described_class.call(remitter_transfer: record, client: client, spreadsheet_id: "sheet-id")
  end

  it "inserts a row in Chương's block with Lập's amount and the TOTAL covers it" do
    client = memory
    record = transfer

    expect(write(record, client)).to eq(:written)

    expect(client.cell("thu chi 1010", "J31")).to eq(29_274_000)
    expect(client.note("thu chi 1010", "J31")).to eq("RT#{record.id} +29274000")
    expect(client.cell("thu chi 1010", "I23")).to eq("Chương\n(MB+SP)")
    expect(client.cell("thu chi 1010", "I33")).to eq("TOTAL")
    expect(client.cell("thu chi 1010", "J33")).to eq("=SUM(J23:J32)")
    expect(client.values("thu chi 1010", "J33").first.first).to eq(18_109_862 + 29_274_000)
    # The whole row moved: the neighbouring block and the cash book too.
    expect(client.cell("thu chi 1010", "A33")).to eq("TOTAL")
    expect(client.cell("thu chi 1010", "B33")).to eq("=SUM(B23:B32)")
    expect(client.cell("thu chi 1010", "A42")).to eq("SP in")

    expect(record.reload).to be_written
    expect(record).to have_attributes(rd_sheet: "thu chi 1010", rd_row: 31, rd_cell: "J31")
  end

  it "adds one more row for the next transfer of the day" do
    client = memory
    write(transfer, client)
    write(transfer(amount: 5_000_000, at: Time.zone.local(2026, 10, 10, 21, 0)), client)

    expect(client.cell("thu chi 1010", "J32")).to eq(5_000_000)
    expect(client.cell("thu chi 1010", "J31")).to eq(29_274_000)
    expect(client.cell("thu chi 1010", "J34")).to eq("=SUM(J23:J33)")
  end

  it "finds the remitter column by its header (I on a tab without LOI)" do
    client = memory("thu chi 1010", tab(remitters: remitters_1010 - [ "LOI" ]))

    write(transfer, client)

    expect(client.cell("thu chi 1010", "I31")).to eq(29_274_000)
  end

  it "uses the tab of the day the transfer was sent" do
    client = Workbook::MemorySheet.new({ "thu chi 1010" => tab, "thu chi 1110" => tab })

    write(transfer(at: Time.zone.local(2026, 10, 11, 23, 50)), client)

    expect(client.cell("thu chi 1110", "J31")).to eq(29_274_000)
    expect(client.cell("thu chi 1010", "J31")).to be_nil
  end

  it "extends a TOTAL that the insert did not grow" do
    # Block with only its label row: the new row goes under the label, below
    # the SUM range, so the formula has to be extended.
    client = memory("thu chi 1010", tab(label_row: 22, total_row: 23))

    write(transfer, client)

    expect(client.cell("thu chi 1010", "J24")).to eq(29_274_000)
    expect(client.cell("thu chi 1010", "J25")).to eq("=SUM(J23:J24)")
  end

  it "leaves a TOTAL that is not a plain SUM alone and notes it" do
    grid = tab(label_row: 22, total_row: 23, total_formula: ->(letter) { "=#{letter}23*1" })
    record = transfer

    write(record, memory("thu chi 1010", grid))

    expect(record.reload.metadata["total_unparsed"]).to include("J25")
  end

  it "does not add a second row when retried after an ambiguous failure" do
    client = memory
    record = transfer
    write(record, client)
    record.update!(written_at: nil, rd_cell: nil)

    expect(write(record, client)).to eq(:already_written)
    expect(client.cell("thu chi 1010", "J32")).to be_nil # still a single new row
    expect(record.reload.rd_cell).to eq("J31")
  end

  it "reports what it cannot place and writes nothing" do
    expect(write(transfer(at: Time.zone.local(2026, 10, 9, 10)), memory)).to eq(:rd_sheet_missing)

    link.update!(rd_agent_label: "Không có")
    record = transfer
    expect(write(record, memory)).to eq(:rd_agent_missing)
    expect(record.reload.metadata["write_issue"]).to eq("rd_agent_missing")
    expect(record).not_to be_written
  end

  it "skips a transfer that is not approved or already written" do
    expect(write(transfer(status: "needs_review"), memory)).to eq(:skipped_not_approved)
    expect(write(transfer(written_at: Time.current), memory)).to eq(:already_written)
  end

  it "adds a column for a new remitter, then the row" do
    lap.update!(excel_key: "MOI")
    client = memory

    write(transfer, client)

    header = client.values("thu chi 1010", "A2:R2").first
    expect(header.count("MOI")).to eq(2)
    record = RemitterTransfer.last
    expect(client.cell("thu chi 1010", record.rd_cell)).to eq(29_274_000)
  end
end
