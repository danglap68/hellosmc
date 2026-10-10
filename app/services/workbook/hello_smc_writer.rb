module Workbook
  # Writes one transaction into the live Hello SMC Google Sheet.
  class HelloSmcWriter
    DS_PREFIX = "DS MB T"
    RD_SHEET = "R&D Report"
    MB_SHEET = "MB"
    UNIDENTIFIED_SHEET = "Bill vô chủ"
    LOCK_KEY = "hello-smc-workbook"

    def self.call(transaction:, client: nil, spreadsheet_id: AppConfig.hello_smc_spreadsheet_id)
      new(transaction:, client:, spreadsheet_id:).call
    end

    def initialize(transaction:, client:, spreadsheet_id:)
      @transaction = transaction
      @client = client
      @spreadsheet_id = spreadsheet_id
    end

    def call
      return :skipped_no_amount if @transaction.transaction_amount_vnd.blank?
      return :skipped_failed if @transaction.failed?
      return :already_written if WorkbookEntry.exists?(transaction_id: @transaction.id)
      return :skipped_unconfigured if @spreadsheet_id.blank?

      client = @client || GoogleSheetClient.new(spreadsheet_id: @spreadsheet_id)
      Transaction.connection.execute(
        Transaction.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", LOCK_KEY ])
      )
      return :already_written if WorkbookEntry.exists?(transaction_id: @transaction.id)

      resolution = Resolver.call(transaction: @transaction)
      if resolution.identified?
        write_identified(client, resolution)
      else
        write_unidentified(client, resolution)
      end
    end

    private

    def write_identified(client, resolution)
      amount = @transaction.transaction_amount_vnd
      ds_sheet, ds_cell = increment_daily(client, resolution.merchant_dealer, amount)
      rd_cell = increment_remitter(client, resolution) if resolution.remitter
      mb_row = append_mb(client, resolution)

      record!(branch: "identified", ds_sheet:, ds_cell:, rd_cell:, mb_row:,
              payload: payload(resolution, issue: rd_cell.nil? && resolution.remitter ? "rd_cell_missing" : nil))
      :identified
    rescue CellMissing
      write_unidentified(client, resolution, issue: "ds_cell_missing")
    end

    def write_unidentified(client, resolution, issue: resolution.issue)
      row = append_unidentified(client)
      record!(branch: "unidentified", unidentified_row: row,
              payload: payload(resolution, issue:))
      :unidentified
    end

    def increment_daily(client, link, amount)
      sheet = monthly_sheet(client)
      grid = client.values(sheet, "A1:X80")
      header_row, header_col = find_cell(grid) { |value| same_text?(value, link.ds_sheet_anchor) }
      raise CellMissing, "ds_anchor" unless header_row

      agent_col = (header_col..[ header_col + 6, 23 ].min).find do |col|
        same_text?(grid.dig(header_row, col), link.ds_header)
      end
      raise CellMissing, "ds_header" unless agent_col

      date_row = ((header_row + 1)...grid.length).find do |row|
        date_of(grid.dig(row, header_col)) == @transaction.transaction_at&.to_date
      end
      raise CellMissing, "ds_date" unless date_row

      current = numeric(grid.dig(date_row, agent_col))
      a1 = a1(date_row, agent_col)
      client.update(sheet, "#{a1}:#{a1}", [ [ current + amount ] ])
      [ sheet, a1 ]
    end

    def increment_remitter(client, resolution)
      grid = client.values(RD_SHEET, "A1:R120")
      label = resolution.merchant_dealer.rd_agent_label
      block_row, block_col = find_cell(grid) { |value| agent_label?(value, label) }
      return nil unless block_row

      remitter_col = remitter_column(grid, block_col, resolution.remitter.excel_key)
      return nil unless remitter_col

      a1 = a1(block_row, remitter_col)
      current = numeric(grid.dig(block_row, remitter_col))
      client.update(RD_SHEET, "#{a1}:#{a1}", [ [ current + @transaction.transaction_amount_vnd ] ])
      a1
    end

    def remitter_column(grid, agent_col, excel_key)
      header_row = 1 # row 2 in A1
      start_col = agent_col + 1
      (start_col..start_col + 4).find { |col| same_text?(grid.dig(header_row, col), excel_key) }
    end

    def append_mb(client, resolution)
      col_a = client.values(MB_SHEET, "A1:A1001").flatten
      row = col_a.index { |value| value.blank? }
      row ||= col_a.length
      n = row + 1
      rate = @transaction.base_fee_rate_used
      percent = formula_percent(rate)
      values = [ [
        @transaction.transaction_amount_vnd,
        "=A#{n}-(A#{n}*D#{n})",
        "=A#{n}-(A#{n}*#{percent})",
        @transaction.applied_dealer_rate&.to_f,
        "=A#{n}*(D#{n}-#{percent})",
        @transaction.lot_number,
        @transaction.transaction_at&.in_time_zone&.strftime("%d/%m/%Y"),
        @transaction.transaction_at&.in_time_zone&.strftime("%H:%M:%S"),
        resolution.merchant_dealer.dealer.name,
        resolution.merchant.name,
        resolution.remitter&.name
      ] ]
      client.update(MB_SHEET, "A#{n}:K#{n}", values)
      n
    end

    def append_unidentified(client)
      col_a = client.values(UNIDENTIFIED_SHEET, "A1:A2000").flatten
      row = col_a.index { |value| value.blank? }
      row ||= col_a.length
      n = row + 1
      rate = @transaction.base_fee_rate_used || BigDecimal("0.0088")
      status = @transaction.approved? || @transaction.exported? ? "Thành công" : "Cần kiểm tra"
      client.update(UNIDENTIFIED_SHEET, "A#{n}:F#{n}", [ [
        @transaction.raw_merchant_name.presence || "—",
        "=C#{n}-(C#{n}*D#{n})",
        @transaction.transaction_amount_vnd,
        rate&.to_f,
        @transaction.transaction_at&.in_time_zone&.strftime("%d/%m/%Y %H:%M:%S"),
        status
      ] ])
      n
    end

    def monthly_sheet(client)
      month = @transaction.transaction_at.in_time_zone.month
      title = "#{DS_PREFIX}#{month}"
      return title if client.titles.include?(title)

      source = client.titles.select { |name| name.start_with?(DS_PREFIX) }.max_by { |name| name.delete_prefix(DS_PREFIX).to_i }
      raise CellMissing, "ds_sheet" unless source

      client.duplicate_sheet(source_title: source, dest_title: title)
      clear_daily_amounts(client, title)
      title
    end

    def clear_daily_amounts(client, title)
      grid = client.values(title, "A1:X80")
      updates = []
      grid.each_with_index do |row, r|
        row.each_with_index do |value, c|
          next unless value.is_a?(Numeric) && r.positive? && date_of(row[0] || row[c - 1])

          updates << [ r, c ]
        end
      end
      updates.each { |r, c| client.update(title, "#{a1(r, c)}:#{a1(r, c)}", [ [ nil ] ]) }
    end

    def record!(**attrs)
      WorkbookEntry.create!(
        recorded_transaction: @transaction,
        spreadsheet_id: @spreadsheet_id,
        amount_vnd: @transaction.transaction_amount_vnd,
        **attrs
      )
    end

    def payload(resolution, issue:)
      {
        "merchant_id" => resolution.merchant&.id,
        "dealer_id" => resolution.merchant_dealer&.dealer_id,
        "tid_key" => resolution.merchant_dealer&.tid_key,
        "remitter_id" => resolution.remitter&.id,
        "issue" => issue,
        "transaction_date" => @transaction.transaction_at&.to_date&.iso8601
      }.compact
    end

    def find_cell(grid)
      grid.each_with_index do |row, r|
        row.each_with_index do |value, c|
          return [ r, c ] if yield(value)
        end
      end
      [ nil, nil ]
    end

    def same_text?(left, right)
      VietnameseText.normalize(left) == VietnameseText.normalize(right)
    end

    def agent_label?(cell, label)
      VietnameseText.normalize(cell.to_s.split("\n").first) == VietnameseText.normalize(label)
    end

    def numeric(value)
      case value
      when Numeric then value
      when String then value.gsub(/[^\d.-]/, "").to_f
      else 0
      end
    end

    def date_of(value)
      case value
      when Date then value
      when Time, DateTime then value.to_date
      when Numeric then Date.new(1899, 12, 30) + value
      when String
        Date.parse(value)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def formula_percent(rate)
      points = (BigDecimal(rate.to_s) * 100).round(2)
      format("%.2f%%", points)
    end

    def a1(row, col)
      letters = ""
      n = col + 1
      while n.positive?
        n, rem = (n - 1).divmod(26)
        letters = (65 + rem).chr + letters
      end
      "#{letters}#{row + 1}"
    end

    class CellMissing < StandardError; end
  end
end
