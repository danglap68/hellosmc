require "rails_helper"

RSpec.describe Workbook::ThuChiTemplate do
  let(:remitters) { [ "LẬP", "KIM", "AN" ] }

  # Two blocks side by side (A: CườngDuyen, E: Chương). Label row 23, three entry
  # rows (24-26), TOTAL row 27, then the manual cash book from row 31.
  def day_tab
    width = (remitters.size + 1) * 2
    grid = Array.new(36) { Array.new(width) }
    [ 0, remitters.size + 1 ].each do |block_col|
      grid[0][block_col] = "AGENT"
      remitters.each_with_index { |name, i| grid[1][block_col + 1 + i] = name }
      grid[26][block_col] = "TOTAL"
      remitters.each_index do |i|
        letter = (65 + block_col + 1 + i).chr
        grid[26][block_col + 1 + i] = "=SUM(#{letter}23:#{letter}26)"
      end
    end
    grid[22][0] = "CườngDuyen\n(MB+SP)"
    grid[22][remitters.size + 1] = "Chương\n(MB+SP)"
    grid[22][1] = 18_109_862                 # the amount typed on a label row
    grid[23][1] = 5_000_000                  # entry rows: written by the system
    grid[24][2] = 7_000_000
    grid[25][remitters.size + 2] = 29_274_000
    grid[25][remitters.size + 3] = 1_500_000.0
    grid[30][0] = "SP in"
    grid[31][1] = 123_456_789                # the manual cash book
    grid
  end

  def sheet
    Workbook::MemorySheet.new({ "Bill vô chủ" => [ [ "x" ] ], "thu chi 1110" => day_tab, "thu chi 1010" => day_tab, "MB" => [ [ "y" ] ] }).tap do |memory|
      memory.set_note("thu chi 1110", "B24", "RT7 +5000000")
      memory.set_note("thu chi 1110", "C25", "RT8 +7000000")
      memory.set_note("thu chi 1110", "A23", "ghi chú của người dùng")
    end
  end

  describe ".build!" do
    it "makes the template from the newest day tab and clears only what the system wrote" do
      client = sheet
      report = described_class.build!(client: client)

      expect(report).to have_attributes(title: "thu chi mẫu", source: "thu chi 1110", amounts_cleared: 4, notes_cleared: 2)
      [ "B24", "C25", "G26", "H26" ].each { |cell| expect(client.cell("thu chi mẫu", cell)).to be_nil.or eq("") }
      expect(client.cell("thu chi mẫu", "B23")).to eq(18_109_862)             # label row amount kept
      expect(client.cell("thu chi mẫu", "B27")).to eq("=SUM(B23:B26)")        # TOTAL formulas kept
      expect(client.cell("thu chi mẫu", "A23")).to eq("CườngDuyen\n(MB+SP)")  # labels kept
      expect(client.cell("thu chi mẫu", "B32")).to eq(123_456_789)            # manual area kept
      expect(client.note("thu chi mẫu", "B24")).to be_nil
      expect(client.note("thu chi mẫu", "C25")).to be_nil
      expect(client.note("thu chi mẫu", "A23")).to eq("ghi chú của người dùng")
    end

    it "leaves the source tab alone and puts the template where the source was" do
      client = sheet
      described_class.build!(client: client)

      expect(client.titles).to eq([ "Bill vô chủ", "thu chi mẫu", "thu chi 1110", "thu chi 1010", "MB" ])
      expect(client.cell("thu chi 1110", "B24")).to eq(5_000_000)
      expect(client.note("thu chi 1110", "B24")).to eq("RT7 +5000000")
    end

    it "builds from the tab asked for" do
      client = sheet
      expect(described_class.build!(client: client, source: "thu chi 1010").source).to eq("thu chi 1010")
    end

    it "refuses to replace an existing template, and needs a day tab to start from" do
      client = sheet
      described_class.build!(client: client)
      expect { described_class.build!(client: client) }.to raise_error(described_class::Error, /Đã có tab/)

      empty = Workbook::MemorySheet.new({ "MB" => [ [ "y" ] ] })
      expect { described_class.build!(client: empty) }.to raise_error(described_class::Error, /Chưa có tab thu chi/)
    end

    it "leaves nothing half built when the clean-up cannot be verified" do
      client = sheet
      allow(client).to receive(:clear_notes)

      expect { described_class.build!(client: client) }.to raise_error(described_class::Error, /ghi chú RT/)
      expect(client.titles).to eq([ "Bill vô chủ", "thu chi 1110", "thu chi 1010", "MB" ])
    end
  end

  describe ".instantiate!" do
    it "copies the template into the day's tab, first among the day tabs" do
      client = sheet
      described_class.build!(client: client)

      title = described_class.instantiate!(client: client, title: "thu chi 1210")

      expect(title).to eq("thu chi 1210")
      expect(client.titles).to eq([ "Bill vô chủ", "thu chi mẫu", "thu chi 1210", "thu chi 1110", "thu chi 1010", "MB" ])
      expect(client.cell("thu chi 1210", "B27")).to eq("=SUM(B23:B26)")
      expect(client.cell("thu chi 1210", "B24")).to be_nil.or eq("")
      expect(client.note("thu chi 1210", "B24")).to be_nil
    end

    it "does nothing without a template" do
      client = sheet

      expect(described_class.instantiate!(client: client, title: "thu chi 1210")).to be_nil
      expect(client.titles).not_to include("thu chi 1210")
    end
  end
end
