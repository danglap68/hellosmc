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
end
