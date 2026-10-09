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

  describe "kết toán theo phí gốc" do
    let(:at) { Time.zone.local(2026, 10, 5, 9, 49, 22) }
    let(:export) { create(:excel_export, export_date: Date.new(2026, 10, 5), layout: "ket_toan_phi_goc", generated_by: admin) }

    def place_transaction(**attrs)
      create(:transaction, :approved, dealer: dealer, merchant: merchant, card_type: normal_card,
        transaction_at: at, amount_after_base_fee_vnd: 1, **attrs)
    end

    it "writes one formula row on the sheet named by the base fee" do
      place_transaction(
        transaction_amount_vnd: 190_001_000,
        applied_base_fee_rate: BigDecimal("0.0121"),
        applied_dealer_rate: BigDecimal("0.014"),
        lot_number: "000038"
      )
      described_class.call(excel_export: export)
      export.reload

      expect(export.transaction_count).to eq(1)
      expect(export.filename).to match(/\Asmc-ket-toan-phi-goc-20261005-\d{6}\.xlsx\z/)
      book = read_sheet(export)
      expect(book.sheets).to eq([ "1,21", "1,17", "1,15" ])
      sheet = book.sheet("1,21")
      expect(sheet.row(2)[0]).to eq(190_001_000)
      expect(sheet.row(2)[3]).to be_within(0.0000001).of(0.014)
      expect(sheet.row(2)[5]).to eq("000038")
      expect(sheet.row(2)[8]).to eq("Anh Trân")
      expect(sheet.row(2)[9]).to eq(merchant.name)
      xml = sheet_xml(export, "1,21")
      expect(formula_at(xml, "B2")).to eq("A2-(A2*D2)")
      expect(formula_at(xml, "C2")).to eq("A2-(A2*1.21%)")
      expect(formula_at(xml, "E2")).to eq("A2*(D2-1.21%)")
      expect(sheet.row(1)[2]).to eq("Số tiền sau khi trừ phí gốc \n(1,21% với thẻ thường, thẻ MB - 0,88%)")
      styles = nil
      Zip::File.open_buffer(StringIO.new(export.file.download)) { |zip| styles = zip.read("xl/styles.xml").force_encoding("UTF-8") }
      expect(styles).to include("&quot;₫&quot;#,##0")
      expect(styles).to include("[Red]\\(&quot;₫&quot;#,##0\\)")
      expect(styles).to include("FF0000")
      expect(styles).to include("FF40FF")
      expect(book.sheet("1,17").last_row).to eq(1)
      expect(book.sheet("1,15").last_row).to eq(1)
    end

    it "keeps an unmapped approved transaction approved and records the skip" do
      kept = place_transaction(applied_base_fee_rate: BigDecimal("0.011"), applied_dealer_rate: BigDecimal("0.014"),
        transaction_amount_vnd: 10_000)
      described_class.call(excel_export: export)

      expect(kept.reload).to be_approved
      expect(export.reload.metadata["skipped"]).to eq([ { "transaction_id" => kept.id, "reason" => "sheet_unmapped" } ])
      expect(AuditLog.find_by!(action: "export.generated").metadata["transaction_ids"]).to eq([])
    end

    it "puts an MB row on the household sheet and writes the card-rule rate in column D" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
      mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      row = place_transaction(card_type: mb_card, applied_base_fee_rate: BigDecimal("0.0121"),
        applied_dealer_rate: BigDecimal("0.014"), transaction_amount_vnd: 1_000_000, lot_number: "1")
      Transactions::Recalculator.call(row, resolve: true)
      row.save!
      described_class.call(excel_export: export)

      expect(row.reload.applied_base_fee_rate).to eq(BigDecimal("0.0121"))
      expect(row.applied_card_base_fee_rate).to eq(BigDecimal("0.0088"))
      expect(row.applied_dealer_rate).to eq(BigDecimal("0.012"))
      sheet = read_sheet(export).sheet("1,21")
      expect(sheet.row(2)[3]).to be_within(0.0000001).of(0.012)
      xml = sheet_xml(export, "1,21")
      expect(formula_at(xml, "C2")).to eq("A2-(A2*0.88%)")
      expect(formula_at(xml, "E2")).to eq("A2*(D2-0.88%)")
      expect(formula_at(xml, "D2")).to be_nil
    end

    it "skips a row whose dealer rate is missing" do
      row = place_transaction(applied_base_fee_rate: BigDecimal("0.0121"), applied_dealer_rate: nil,
        transaction_amount_vnd: 10_000)
      described_class.call(excel_export: export)
      expect(row.reload).to be_approved
      expect(export.reload.metadata["skipped"]).to eq([ { "transaction_id" => row.id, "reason" => "dealer_rate_missing" } ])
    end

    it "sums only the money columns" do
      2.times do |index|
        place_transaction(applied_base_fee_rate: BigDecimal("0.0121"), applied_dealer_rate: BigDecimal("0.014"),
          transaction_amount_vnd: 1_000 + index, lot_number: index.to_s, transaction_at: at + index.minutes)
      end
      described_class.call(excel_export: export)
      xml = sheet_xml(export, "1,21")
      expect(formula_at(xml, "A4")).to eq("SUM(A2:A3)")
      expect(formula_at(xml, "B4")).to eq("SUM(B2:B3)")
      expect(formula_at(xml, "C4")).to eq("SUM(C2:C3)")
      expect(formula_at(xml, "E4")).to eq("SUM(E2:E3)")
      expect(formula_at(xml, "D4")).to be_nil
    end
  end

  def sheet_xml(export, sheet_name)
    require "zip"
    xml = nil
    # open_buffer returns its output buffer, not the block result, so keep xml outside.
    Zip::File.open_buffer(StringIO.new(export.file.download)) do |zip|
      book = zip.read("xl/workbook.xml")
      rels = zip.read("xl/_rels/workbook.xml.rels")
      tag = book[/<sheet\b[^>]*name="#{Regexp.escape(sheet_name)}"[^>]*>/]
      rid = tag[/r:id="([^"]+)"/, 1]
      relationship = rels.scan(/<Relationship\b[^>]*>/).find { |item| item.include?(%(Id="#{rid}")) }
      target = relationship[/Target="([^"]+)"/, 1]
      path = target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
      xml = zip.read(path)
    end
    xml
  end

  def formula_at(xml, ref)
    xml[/r="#{ref}"[^>]*>\s*<f[^>]*>([^<]*)<\/f>/m, 1]
  end
end
