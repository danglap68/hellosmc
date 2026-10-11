require "rails_helper"

RSpec.describe Workbook::MemorySheet do
  it "reads a rectangular range" do
    sheet = described_class.new("MB" => [[1, 2, 3], [4, 5, 6]])
    expect(sheet.values("MB", "A1:C2")).to eq([[1, 2, 3], [4, 5, 6]])
  end

  it "writes into a range" do
    sheet = described_class.new("MB" => [[nil]])
    sheet.update("MB", "A1:A1", [[99]])
    expect(sheet.cell("MB", "A1")).to eq(99)
  end

  it "duplicates a sheet" do
    sheet = described_class.new("DS MB T10" => [[1, 2], [3, 4]])
    sheet.duplicate_sheet(source_title: "DS MB T10", dest_title: "DS MB T11")
    expect(sheet.titles).to include("DS MB T11")
    expect(sheet.values("DS MB T11", "A1:B2")).to eq([[1, 2], [3, 4]])
  end

  it "applies a batch of updates" do
    sheet = described_class.new("MB" => [[nil], [nil]], "RD" => [[nil]])
    sheet.batch_update_values([
      { sheet: "MB", range: "A1:A2", rows: [[1], [2]] },
      { sheet: "RD", range: "A1:A1", rows: [[9]] }
    ])
    expect(sheet.cell("MB", "A1")).to eq(1)
    expect(sheet.cell("MB", "A2")).to eq(2)
    expect(sheet.cell("RD", "A1")).to eq(9)
  end

  describe "behaves like the Sheets API" do
    it "returns [] for an empty row in the middle and drops trailing empty rows" do
      sheet = described_class.new("MB" => [ [ "h" ], [ 1 ], [], [ 3 ], [], [] ])
      expect(sheet.values("MB", "A:A")).to eq([ [ "h" ], [ 1 ], [], [ 3 ] ])
    end

    it "skips nil and clears a cell on an empty string when writing" do
      sheet = described_class.new("MB" => [ [ 1, 2 ] ])
      sheet.update("MB", "A1:B1", [ [ nil, "" ] ])
      expect(sheet.values("MB", "A1:B1")).to eq([ [ 1 ] ])
    end

    it "treats a leading apostrophe as literal text and ISO dates as dates" do
      sheet = described_class.new("MB" => [ [ nil, nil ] ])
      sheet.update("MB", "A1:B1", [ [ "'=1+1", "2026-11-01" ] ])
      expect(sheet.cell("MB", "A1")).to eq("=1+1")
      expect(sheet.cell("MB", "B1")).to eq(Date.new(2026, 11, 1))
      expect(sheet.values("MB", "B1:B1")).to eq([ [ (Date.new(2026, 11, 1) - Date.new(1899, 12, 30)).to_i ] ])
    end

    it "evaluates =SUM unless FORMULA rendering is requested" do
      sheet = described_class.new("MB" => [ [ 1 ], [ 2 ], [ "=sum(A1:A2)" ] ])
      expect(sheet.values("MB", "A3:A3")).to eq([ [ 3 ] ])
      expect(sheet.values("MB", "A3:A3", value_render_option: "FORMULA")).to eq([ [ "=sum(A1:A2)" ] ])
    end

    it "refuses to write past the row limit until rows are added" do
      sheet = described_class.new({ "MB" => [ [ 1 ] ] }, { "MB" => 1 })
      expect { sheet.update("MB", "A2:A2", [ [ 2 ] ]) }.to raise_error(described_class::GridLimitError)
      sheet.ensure_rows("MB", 2)
      sheet.update("MB", "A2:A2", [ [ 2 ] ])
      expect(sheet.cell("MB", "A2")).to eq(2)
    end

    it "renames and deletes sheets" do
      sheet = described_class.new("a" => [ [ 1 ] ], "b" => [ [ 2 ] ])
      sheet.rename_sheet(from: "a", to: "c")
      sheet.delete_sheet("b")
      expect(sheet.titles).to eq([ "c" ])
    end
  end

  it "inserts a column for the block rows only" do
    sheet = described_class.new("T" => [ [ 1, 2, 3 ], [ 4, 5, 6 ], [ 7, 8, 9 ] ])
    sheet.insert_columns("T", col: 1, end_row: 2)
    expect(sheet.sheets["T"]).to eq([ [ 1, nil, 2, 3 ], [ 4, nil, 5, 6 ], [ 7, 8, 9 ] ])
  end
end
