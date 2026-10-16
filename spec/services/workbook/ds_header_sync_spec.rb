require "rails_helper"

RSpec.describe Workbook::DsHeaderSync do
  let(:hkd) { create(:merchant, name: "Cherry Coffee", code: "CHERRY001") }
  let(:nghia) { create(:dealer, name: "Nghĩa Nghiệp") }
  let(:lan) { create(:dealer, name: "Lan") }
  let(:now) { Time.zone.local(2026, 10, 16, 10, 0) }
  let!(:tid1) { create(:merchant_dealer, merchant: hkd, dealer: nghia, tid_key: "tid1", ds_sheet_anchor: "Cherry Coffee", ds_header: "Nghĩa Nghiệp (tid1)") }
  let!(:tid2) { create(:merchant_dealer, merchant: hkd, dealer: create(:dealer, name: "Trân"), tid_key: "tid2", ds_sheet_anchor: "Cherry Coffee", ds_header: "Trân(tid2)") }

  def sync(header_tid1:, header_tid2: "Trân(tid2)", apply: true, client: nil)
    client ||= Workbook::MemorySheet.new("DS MB T10" => [ [ "Cherry Coffee", header_tid1, header_tid2 ] ])
    described_class.call(client: client, spreadsheet_id: "sheet-id", apply: apply, now: now)
  end

  def statuses(report)
    report.rows.to_h { |row| [ row.link.tid_key, row.status ] }
  end

  it "reads this month's tab and reports each agent" do
    report = sync(header_tid1: "Nghĩa Nghiệp (tid1)")

    expect(report.sheet).to eq("DS MB T10")
    expect(statuses(report)).to eq("tid1" => :ok, "tid2" => :ok)
    expect(report.counts).to include(ok: 2, renamed: 0)
  end

  it "saves a renamed header" do
    report = sync(header_tid1: "Nghĩa (tid1)")

    expect(statuses(report)["tid1"]).to eq(:renamed)
    expect(tid1.reload.ds_header).to eq("Nghĩa (tid1)")
  end

  it "gives the row to the dealer the header names" do
    lan
    report = sync(header_tid1: "Lan (tid1)")

    expect(statuses(report)["tid1"]).to eq(:switched)
    expect(tid1.reload).to have_attributes(dealer: lan, ds_header: "Lan (tid1)")
    expect(AuditLog.find_by!(action: "merchant_dealer.agent_switched").metadata).to include("source" => "sync")
  end

  it "leaves a name nobody has, and a switch while the setting is off, unmatched" do
    lan
    expect(statuses(sync(header_tid1: "Minh Quân (tid1)"))["tid1"]).to eq(:unmatched)

    AppSetting.create!(key: "ds_header_auto_switch", value: "false")
    expect(statuses(sync(header_tid1: "Lan (tid1)"))["tid1"]).to eq(:unmatched)
    expect(tid1.reload).to have_attributes(dealer: nghia, ds_header: "Nghĩa Nghiệp (tid1)")
  end

  it "changes nothing when asked only to check" do
    lan
    report = sync(header_tid1: "Lan (tid1)", apply: false)

    expect(statuses(report)["tid1"]).to eq(:switched)
    expect(tid1.reload).to have_attributes(dealer: nghia, ds_header: "Nghĩa Nghiệp (tid1)")
    expect(AuditLog.where(action: "merchant_dealer.agent_switched")).to be_empty
  end

  it "reports an agent whose column is not in the tab" do
    expect(statuses(sync(header_tid1: "Nghĩa Nghiệp (tid1)", header_tid2: nil))["tid2"]).to eq(:missing)
  end

  it "limits the check to the given HKDs" do
    other = create(:merchant_dealer, ds_sheet_anchor: "Khác", ds_header: "A (tid1)", tid_key: "tid1")
    client = Workbook::MemorySheet.new("DS MB T10" => [ [ "Cherry Coffee", "Nghĩa Nghiệp (tid1)", "Trân(tid2)" ] ])

    report = described_class.call(merchants: [ hkd ], client: client, spreadsheet_id: "sheet-id", now: now)

    expect(report.rows.map(&:link)).to contain_exactly(tid1, tid2)
    expect(report.rows.map(&:link)).not_to include(other)
  end

  it "fails when the month's tab does not exist" do
    client = Workbook::MemorySheet.new("DS MB T9" => [ [ "Cherry Coffee" ] ])

    expect { described_class.call(client: client, spreadsheet_id: "sheet-id", now: now) }
      .to raise_error(described_class::SheetMissing, "DS MB T10")
  end
end
