require "rails_helper"

RSpec.describe Workbook::DsHeaderMatcher do
  let(:hkd) { create(:merchant, name: "Cherry Coffee", code: "CHERRY001") }
  let(:nghia) { create(:dealer, name: "Nghĩa Nghiệp") }
  let!(:link) do
    create(:merchant_dealer, merchant: hkd, dealer: nghia, tid_key: "tid1",
           ds_sheet_anchor: "Cherry Coffee", ds_header: "Nghĩa Nghiệp (tid1)")
  end
  let(:last_col) { 23 }

  def match(row, record: link)
    described_class.call(grid: [ row ], header_row: 0, anchor_col: 0, link: record, last_col: last_col)
  end

  describe "finding the column" do
    it "finds the column by TID when the header text changed" do
      result = match([ "Cherry Coffee", "Cường Duyên(tid2)", "Trân ( tid3)", "Nghĩa (tid1)" ])

      expect(result.col).to eq(3)
      expect(result.header).to eq("Nghĩa (tid1)")
    end

    it "reads the TID in any spelling" do
      expect(match([ "Cherry Coffee", "Nghĩa Nghiệp (tid 1)" ]).col).to eq(1)
      expect(match([ "Cherry Coffee", "Nghĩa Nghiệp (TID 1)" ]).col).to eq(1)
    end

    it "returns nil when no header has the TID" do
      expect(match([ "Cherry Coffee", "Cường Duyên(tid2)", "Trân ( tid3)" ])).to be_nil
    end

    it "returns nil when two headers of the block have the TID" do
      expect(match([ "Cherry Coffee", "Nghĩa (tid1)", "Lan (tid1)" ])).to be_nil
    end

    it "skips a header that already belongs to another agent of the HKD" do
      create(:merchant_dealer, merchant: hkd, dealer: create(:dealer, name: "Cường Duyên"), tid_key: "tid2",
             ds_sheet_anchor: "Cherry Coffee", ds_header: "Cường Duyên (tid1)")

      expect(match([ "Cherry Coffee", "Cường Duyên (tid1)", "Nghĩa (tid1)" ]).col).to eq(2)
    end

    it "stops at the first blank header so the next HKD is not read" do
      expect(match([ "Cherry Coffee", "Trân ( tid3)", nil, "Anh Hải (tid 1)" ])).to be_nil
    end

    it "does not look past the last column" do
      row = [ "Cherry Coffee" ] + Array.new(4) { |i| "Người #{i} (tid#{i + 2})" } + [ "Nghĩa (tid1)" ]
      result = described_class.call(grid: [ row ], header_row: 0, anchor_col: 0, link: link, last_col: 4)

      expect(result).to be_nil
    end
  end

  describe "kind of change" do
    it "is same when the person is the current dealer, whatever the spacing or channel" do
      expect(match([ "Cherry Coffee", "Nghĩa Nghiệp ( tid 1)" ]).kind).to eq(:same)
      expect(match([ "Cherry Coffee", "NGHĨA NGHIỆP MB (tid1)" ]).kind).to eq(:same)
    end

    it "is rename when the name is a shorter or longer form of the current dealer" do
      shorter = match([ "Cherry Coffee", "Nghĩa (tid1)" ])
      longer = match([ "Cherry Coffee", "Anh Nghĩa Nghiệp (tid1)" ])

      expect([ shorter.kind, shorter.dealer ]).to eq([ :rename, nghia ])
      expect(longer.kind).to eq(:rename)
    end

    it "is switch when the name is exactly another active dealer" do
      lan = create(:dealer, name: "Lan")

      result = match([ "Cherry Coffee", "Lan (tid1)" ])

      expect([ result.kind, result.dealer ]).to eq([ :switch, lan ])
    end

    it "prefers switch to rename when the shorter name is another existing dealer" do
      link.update!(dealer: create(:dealer, name: "Hải"), ds_header: "Hải (tid1)")
      anh_hai = create(:dealer, name: "Anh Hải")

      result = match([ "Cherry Coffee", "Anh Hải (tid1)" ])

      expect([ result.kind, result.dealer ]).to eq([ :switch, anh_hai ])
    end

    it "is unmatched for a name no dealer has" do
      result = match([ "Cherry Coffee", "Minh Quân (tid1)" ])

      expect([ result.kind, result.dealer ]).to eq([ :unmatched, nil ])
    end

    it "is unmatched when the only dealer with that name is inactive" do
      create(:dealer, name: "Lan", active: false)

      expect(match([ "Cherry Coffee", "Lan (tid1)" ]).kind).to eq(:unmatched)
    end

    it "is unmatched when several dealers carry the name" do
      create(:dealer, name: "Lan")
      create(:dealer, name: "LAN")

      expect(match([ "Cherry Coffee", "Lan (tid1)" ]).kind).to eq(:unmatched)
    end

    it "is unmatched when the header carries no name" do
      expect(match([ "Cherry Coffee", "(tid1)" ]).kind).to eq(:unmatched)
      expect(match([ "Cherry Coffee", "A (tid1)" ]).kind).to eq(:unmatched)
    end
  end

  describe ".locate" do
    def locate(grid)
      described_class.locate(grid: grid, link: link, last_col: last_col)
    end

    it "finds the column by the header text without calling it a change" do
      location = locate([ [ "x" ], [ "Cherry Coffee", "Cường Duyên(tid2)", "Nghĩa Nghiệp (tid1)" ] ])

      expect(location).to have_attributes(header_row: 1, anchor_col: 0, col: 2, change: nil)
    end

    it "falls back to the TID and reports the change" do
      location = locate([ [ "Cherry Coffee", "Nghĩa (tid1)" ] ])

      expect(location).to have_attributes(col: 1)
      expect(location.change).to have_attributes(kind: :rename, header: "Nghĩa (tid1)")
    end

    it "is nil without the HKD's cell, and has no column when none carries the TID" do
      expect(locate([ [ "Gat Tan Day Coffe", "Nghĩa (tid1)" ] ])).to be_nil
      expect(locate([ [ "Cherry Coffee", "Trân (tid3)" ] ]).col).to be_nil
    end
  end
end
