require "rails_helper"
require "roo"

RSpec.describe Exports::ExcelGenerator do
  include_context "accounting setup"

  let(:admin) { create(:user, :admin) }
  let!(:approved) { Transactions::Builder.call(bill_image: analyzed_bill).sole }
  let!(:held) do
    transaction = Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole
    Transactions::StatusUpdater.call(transaction: transaction, actor: admin, action: "hold")
    transaction
  end
  let(:export) { create(:excel_export, export_date: Date.new(2026, 10, 4), generated_by: admin) }

  def read_sheet(export)
    path = Rails.root.join("tmp", "spec-export-#{export.id}.xlsx")
    File.binwrite(path, export.file.download)
    Roo::Excelx.new(path.to_s)
  end

  it "writes legacy headers and maps statuses" do
    described_class.call(excel_export: export)
    export.reload

    expect(export).to be_completed
    expect(export.transaction_count).to eq(2)
    expect(export.file).to be_attached

    sheet = read_sheet(export).sheet("Giao dịch")
    expect(sheet.row(1).first(6)).to eq([ "Tên Đại lý", "Số tiền sau khi trừ phí gốc", "Số tiền giao dịch", "Phí gốc", "Ngày giao dịch", "Trạng thái" ])
    approved_row = sheet.row(2)
    expect(approved_row[0]).to eq("001_ HỘ KINH DOANH THIÊN KIM GV")
    expect(approved_row[1]).to eq(11_344_284)
    expect(approved_row[2]).to eq(11_445_000)
    expect(approved_row[3]).to be_within(0.000001).of(0.0088)
    expect(approved_row[5]).to eq("Thành công")
    expect(approved_row[6]).to eq("Anh Trân")
    expect(sheet.column(6)).to include("bill hold")
  end

  it "marks approved transactions exported and audits the export" do
    described_class.call(excel_export: export)

    expect(approved.reload).to be_exported
    expect(approved.excel_export).to eq(export)
    expect(held.reload).to be_hold
    log = AuditLog.find_by!(action: "export.generated")
    expect(log.actor_user).to eq(admin)
    expect(log.metadata["transaction_ids"]).to match_array([ approved.id, held.id ])
  end

  it "excludes transactions outside the range or still in review" do
    Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement"))
    other_day = create(:excel_export, export_date: Date.new(2026, 10, 3))
    described_class.call(excel_export: other_day)
    expect(other_day.reload.transaction_count).to eq(0)
  end
end
