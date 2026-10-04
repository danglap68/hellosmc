require "axlsx"

module Exports
  # Builds the accounting workbook for a date range. PostgreSQL stays the
  # source of truth; the workbook is an output. Approved transactions are
  # marked exported; hold transactions are listed with status "bill hold".
  class ExcelGenerator
    CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

    def self.call(excel_export:)
      new(excel_export).call
    end

    def initialize(excel_export)
      @export = excel_export
    end

    def call
      @export.update!(status: "processing", error_message: nil)
      transactions = nil

      # Rows are locked while the workbook is built so a concurrent hold or
      # edit cannot make the file disagree with the database.
      Transaction.transaction do
        transactions = scope.lock.to_a
        bytes = build_workbook(transactions)
        @export.file.attach(io: StringIO.new(bytes), filename: @export.filename, content_type: CONTENT_TYPE,
                            key: "exports/#{Time.current.strftime('%Y/%m')}/#{SecureRandom.uuid}.xlsx", identify: false)
        mark_exported(transactions)
        @export.update!(
          status: "completed",
          transaction_count: transactions.size,
          generated_at: Time.current,
          storage_key: @export.file.blob.key,
          metadata: @export.metadata.merge("totals" => AuditLogger.serialize(totals(transactions)))
        )
        AuditLogger.log!(actor: @export.generated_by, action: "export.generated", auditable: @export,
                         after_data: { "transaction_count" => transactions.size,
                                       "date_from" => @export.export_date, "date_to" => @export.end_date },
                         metadata: { "transaction_ids" => transactions.map(&:id) })
      end
      StructuredLog.info("export.generated", excel_export_id: @export.id, transaction_count: transactions.size)
      @export
    rescue StandardError => e
      @export.update_columns(status: "failed", error_message: e.message.truncate(2000), updated_at: Time.current)
      StructuredLog.error("export.failed", excel_export_id: @export.id, error_class: e.class.name, error: e.message)
      raise
    end

    private

    def scope
      zone = Time.zone
      from = zone.local(@export.export_date.year, @export.export_date.month, @export.export_date.day)
      to = zone.local(@export.end_date.year, @export.end_date.month, @export.end_date.day).end_of_day
      Transaction.where(status: LegacyLayout::EXPORTABLE_STATUSES, transaction_at: from..to)
        .includes(:merchant, :dealer)
        .order(:transaction_at, :id)
    end

    def build_workbook(transactions)
      package = Axlsx::Package.new
      package.use_shared_strings = true
      workbook = package.workbook
      styles = build_styles(workbook)

      workbook.add_worksheet(name: "Giao dịch") do |sheet|
        sheet.add_row LegacyLayout.headers, style: styles[:header]
        transactions.each do |transaction|
          sheet.add_row LegacyLayout.row(transaction),
            style: LegacyLayout::COLUMNS.map { |column| styles[column.type] },
            types: LegacyLayout::COLUMNS.map { |column| cell_type(column.type) }
        end
        sheet.column_widths 42, 24, 20, 10, 20, 14, 22
      end

      workbook.add_worksheet(name: "Tổng hợp") do |sheet|
        sheet.add_row [ "Đại lý", "Số giao dịch thành công", "Tổng số tiền giao dịch",
                        "Tổng số tiền sau khi trừ phí gốc", "Số bill hold", "Tổng tiền bill hold" ], style: styles[:header]
        totals(transactions)["by_dealer"].each do |dealer_name, row|
          sheet.add_row [ dealer_name, row["success_count"], row["transaction_amount_vnd"],
                          row["amount_after_base_fee_vnd"], row["hold_count"], row["hold_amount_vnd"] ],
            style: [ nil, nil, styles[:integer], styles[:integer], nil, styles[:integer] ]
        end
        sheet.column_widths 30, 24, 24, 30, 14, 20
      end

      package.to_stream.read
    end

    def build_styles(workbook)
      s = workbook.styles
      {
        header: s.add_style(b: true, bg_color: "E9ECEF", border: { style: :thin, color: "CED4DA" }),
        string: nil,
        integer: s.add_style(num_fmt: 3),
        rate: s.add_style(format_code: "0.0000"),
        datetime: s.add_style(format_code: "dd/mm/yyyy hh:mm:ss")
      }
    end

    def cell_type(type)
      { string: :string, integer: :integer, rate: :float, datetime: :time }.fetch(type)
    end

    def totals(transactions)
      by_dealer = Hash.new do |hash, key|
        hash[key] = { "success_count" => 0, "transaction_amount_vnd" => 0, "amount_after_base_fee_vnd" => 0,
                      "hold_count" => 0, "hold_amount_vnd" => 0 }
      end
      transactions.each do |t|
        row = by_dealer[t.dealer&.name || "—"]
        if t.hold?
          row["hold_count"] += 1
          row["hold_amount_vnd"] += t.transaction_amount_vnd.to_i
        else
          row["success_count"] += 1
          row["transaction_amount_vnd"] += t.transaction_amount_vnd.to_i
          row["amount_after_base_fee_vnd"] += t.amount_after_base_fee_vnd.to_i
        end
      end
      { "by_dealer" => by_dealer.sort.to_h }
    end

    def mark_exported(transactions)
      now = Time.current
      transactions.each do |transaction|
        export_ids = Array(transaction.source_data["export_ids"]) | [ @export.id ]
        attributes = { excel_export: @export, source_data: transaction.source_data.merge("export_ids" => export_ids) }
        if transaction.approved?
          transaction.transition_to!("exported", exported_at: now, **attributes)
        else
          transaction.update!(attributes.except(:excel_export))
        end
      end
    end
  end
end
