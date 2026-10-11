module Workbook
  # Writes one transaction into the live Hello SMC Google Sheet.
  #
  # Every cell of one transaction goes out in a single values.batchUpdate, so a
  # partial write cannot leave the sheet half-updated. Writes are serialized per
  # spreadsheet with a session-level Postgres advisory lock.
  class HelloSmcWriter
    DS_PREFIX = "DS MB T"
    RD_SHEET = "R&D Report"
    MB_SHEET = "MB"
    UNIDENTIFIED_SHEET = "Bill vô chủ"

    class ConfigurationError < StandardError; end
    class CellMissing < StandardError; end

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
      return :skipped_no_date if @transaction.transaction_at.blank?
      return :already_written if WorkbookEntry.exists?(transaction_id: @transaction.id)
      raise ConfigurationError, "hello_smc_spreadsheet_id is not configured" if @spreadsheet_id.blank?

      client = @client || GoogleSheetClient.new(spreadsheet_id: @spreadsheet_id)
      with_advisory_lock do
        return :already_written if WorkbookEntry.exists?(transaction_id: @transaction.id)

        resolution = Resolver.call(transaction: @transaction)
        resolution.identified? ? write_identified(client, resolution) : write_unidentified(client, resolution)
      end
    end

    private

    def write_identified(client, resolution)
      amount = @transaction.transaction_amount_vnd
      ds_update, ds_cell, ds_sheet = increment_daily(client, resolution.merchant_dealer, amount)
      updates = [ ds_update ]

      rd_cell = nil
      if resolution.remitter
        rd_update, rd_cell = increment_remitter(client, resolution, amount)
        updates << rd_update if rd_update
      end

      mb_row, mb_update = append_mb(client, resolution)
      updates << mb_update

      client.batch_update_values(updates)
      record!(branch: "identified", ds_sheet:, ds_cell:, rd_cell:, mb_row:,
              payload: payload(resolution, issue: rd_cell.nil? && resolution.remitter ? "rd_cell_missing" : nil))
      :identified
    rescue CellMissing
      write_unidentified(client, resolution, issue: "ds_cell_missing")
    end

    def write_unidentified(client, resolution, issue: resolution.issue)
      row, update = append_unidentified(client)
      client.batch_update_values([ update ])
      record!(branch: "unidentified", unidentified_row: row, payload: payload(resolution, issue:))
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
      cell = a1(date_row, agent_col)
      [ { sheet: sheet, range: "#{cell}:#{cell}", rows: [ [ current + amount ] ] }, cell, sheet ]
    end

    def increment_remitter(client, resolution, amount)
      grid = client.values(RD_SHEET, "A1:R120")
      label = resolution.merchant_dealer.rd_agent_label
      block_row, block_col = find_cell(grid) { |value| agent_label?(value, label) }
      return [ nil, nil ] unless block_row

      remitter_col = remitter_column(grid, block_col, resolution.remitter.excel_key)
      return [ nil, nil ] unless remitter_col

      cell = a1(block_row, remitter_col)
      current = numeric(grid.dig(block_row, remitter_col))
      [ { sheet: RD_SHEET, range: "#{cell}:#{cell}", rows: [ [ current + amount ] ] }, cell ]
    end

    def remitter_column(grid, agent_col, excel_key)
      # R&D Report layout is fixed: row 1 = "AGENT/RIMITTER" header, row 2 = remitter names.
      header_row = 1
      start_col = agent_col + 1
      (start_col..start_col + 4).find { |col| same_text?(grid.dig(header_row, col), excel_key) }
    end

    def append_mb(client, resolution)
      col_a = client.values(MB_SHEET, "A1:A1001").flatten
      row = col_a.index { |value| value.blank? }
      row ||= col_a.length
      n = row + 1

      percent = percent_formula(@transaction.base_fee_rate_used)
      c_formula = percent && "=A#{n}-(A#{n}*#{percent})"
      e_formula = percent && "=A#{n}*(D#{n}-#{percent})"

      values = [ [
        @transaction.transaction_amount_vnd,
        "=A#{n}-(A#{n}*D#{n})",
        c_formula,
        @transaction.applied_dealer_rate&.to_f,
        e_formula,
        @transaction.lot_number,
        @transaction.transaction_at&.in_time_zone&.strftime("%d/%m/%Y"),
        @transaction.transaction_at&.in_time_zone&.strftime("%H:%M:%S"),
        resolution.merchant_dealer.dealer.name,
        resolution.merchant.name,
        resolution.remitter&.name
      ] ]
      [ n, { sheet: MB_SHEET, range: "A#{n}:K#{n}", rows: values } ]
    end

    def append_unidentified(client)
      col_a = client.values(UNIDENTIFIED_SHEET, "A1:A2000").flatten
      row = col_a.index { |value| value.blank? }
      row ||= col_a.length
      n = row + 1

      rate = @transaction.base_fee_rate_used || BigDecimal("0.0088")
      status = (@transaction.approved? || @transaction.exported?) ? "Thành công" : "Cần kiểm tra"
      values = [ [
        @transaction.raw_merchant_name.presence || "—",
        "=C#{n}-(C#{n}*D#{n})",
        @transaction.transaction_amount_vnd,
        rate&.to_f,
        @transaction.transaction_at&.in_time_zone&.strftime("%d/%m/%Y %H:%M:%S"),
        status
      ] ]
      [ n, { sheet: UNIDENTIFIED_SHEET, range: "A#{n}:F#{n}", rows: values } ]
    end

    def monthly_sheet(client)
      month = @transaction.transaction_at.in_time_zone.month
      title = "#{DS_PREFIX}#{month}"
      return title if client.titles.include?(title)

      source = client.titles.select { |name| name.start_with?(DS_PREFIX) }
        .max_by { |name| name.delete_prefix(DS_PREFIX).to_i }
      raise CellMissing, "ds_sheet" unless source

      client.duplicate_sheet(source_title: source, dest_title: title)
      client.batch_update_values(month_setup_updates(client, title))
      title
    end

    # Rewrites the date column to the new month and blanks every amount cell,
    # leaving the SUM formulas untouched.
    def month_setup_updates(client, title)
      grid = client.values(title, "A1:X80")
      month = @transaction.transaction_at.in_time_zone.month
      year = @transaction.transaction_at.in_time_zone.year
      days_in_month = Date.new(year, month, -1).day

      updates = []
      grid.each_with_index do |row, r|
        next if r.zero?

        row.each_with_index do |value, c|
          next if value.nil?

          day = date_of(value)
          if day
            # Write an ISO string so Google (USER_ENTERED) stores it as a date;
            # the writer reads dates back as serials via UNFORMATTED_VALUE.
            new_date = (day.day <= days_in_month) ? Date.new(year, month, day.day).iso8601 : nil
            updates << { sheet: title, range: "#{a1(r, c)}:#{a1(r, c)}", rows: [ [ new_date ] ] }
          elsif value.is_a?(Numeric)
            updates << { sheet: title, range: "#{a1(r, c)}:#{a1(r, c)}", rows: [ [ nil ] ] }
          end
        end
      end
      updates
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

    def with_advisory_lock
      key = "hello-smc-workbook:#{@spreadsheet_id}"
      connection = Transaction.connection
      connection.execute(Transaction.sanitize_sql_array([ "SELECT pg_advisory_lock(hashtext(?))", key ]))
      begin
        yield
      ensure
        connection.execute(Transaction.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtext(?))", key ]))
      end
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
      normalize_text(left) == normalize_text(right)
    end

    # Diacritic/space-insensitive, and "tid 1" == "tid1" == "TID 1".
    def normalize_text(text)
      VietnameseText.normalize(text).gsub(/\btid\s+(\d+)\b/i, 'tid\1')
    end

    # R&D labels are multi-line: the first line is the agent name, the rest is
    # the channel ("(MB+SP)", "(SP)", …). Also tolerate a single-line "(MB+SP)".
    def agent_label?(cell, label)
      normalized = normalize_text(cell.to_s.split("\n").first).sub(/\s+mb\s+sp\z/, "")
      normalized == normalize_text(label)
    end

    def numeric(value)
      case value
      when Numeric then value
      when String then value.gsub(/[^\d.-]/, "").to_f
      else 0
      end
    end

    # Dates come back as Excel serial numbers (UNFORMATTED_VALUE); amounts are
    # large numbers and must not be mistaken for dates. ISO strings are also
    # accepted so month-rollover dates written by this writer round-trip.
    def date_of(value)
      case value
      when Date then value
      when Time, DateTime then value.to_date
      when Numeric
        serial = value.to_i
        return nil unless serial.between?(1, 110_000)

        Date.new(1899, 12, 30) + serial
      when String
        Date.iso8601(value.strip) if value.strip.present?
      end
    rescue ArgumentError, TypeError
      nil
    end

    def percent_formula(rate)
      Exports::KetToanPhiGocLayout.formula_percent_for(rate)
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
  end
end
