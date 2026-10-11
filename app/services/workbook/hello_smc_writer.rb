module Workbook
  # Writes one transaction into the live Hello SMC Google Sheet.
  #
  # Every cell of one transaction goes out in a single values.batchUpdate, so a
  # partial write cannot leave the sheet half-updated. Writes are serialized per
  # spreadsheet with a session-level Postgres advisory lock (try-lock: a busy
  # lock raises LockBusy and the job retries, so Sidekiq threads never block).
  #
  # Idempotency: every ledger row carries a "TX<id>" marker (MB column L,
  # "Bill vô chủ" column G). A retry after an ambiguous failure (timeout after
  # Google applied the batch, crash before the DB entry was saved) finds the
  # marker and only records the entry instead of adding the amount twice.
  #
  # Remitters are not part of a transaction: the "thu chi" tab is written from
  # RemitterTransfer (Workbook::RemitterReportWriter), and MB column K
  # ("Người đi tiền") is left empty.
  class HelloSmcWriter
    include SheetText

    DS_PREFIX = "DS MB T"
    SETUP_PREFIX = "__setup_"
    MB_SHEET = "MB"
    UNIDENTIFIED_SHEET = "Bill vô chủ"

    DS_READ_RANGE = "A1:X80"
    DS_LAST_COL = 23
    # A DS MB day cell the writer keeps as a running sum: "=354367000+486000".
    RUNNING_SUM = /\A=\s*-?\d+(?:\s*[+-]\s*\d+)*\s*\z/
    # Whole-column reads return only the used rows, so the ledgers can grow.
    MB_READ_RANGE = "A:L"
    MB_MARKER_COL = 11
    UNIDENTIFIED_READ_RANGE = "A:G"
    UNIDENTIFIED_MARKER_COL = 6

    # Serial numbers for 2000-01-01..2099-12-31; keeps small amounts from
    # being mistaken for dates.
    DATE_SERIAL_RANGE = (36_526..73_415)
    MIN_DATE_RUN = 5

    class ConfigurationError < StandardError; end
    class CellMissing < StandardError; end
    class LockBusy < StandardError; end

    DateRun = Struct.new(:col, :rows)

    def self.call(transaction:, client: nil, spreadsheet_id: AppConfig.hello_smc_spreadsheet_id)
      new(transaction: transaction, client: client, spreadsheet_id: spreadsheet_id).call
    end

    def initialize(transaction:, client:, spreadsheet_id:)
      @transaction = transaction
      @client = client
      @spreadsheet_id = spreadsheet_id
    end

    def call
      return :skipped_no_amount if @transaction.transaction_amount_vnd.blank?
      return :skipped_failed if @transaction.failed?
      return :skipped_rejected if @transaction.rejected?
      # Only reviewed money goes into the sheet: pending / needs_review / hold
      # are written after approval (Transactions::Approver enqueues the job).
      return :skipped_not_approved unless @transaction.finalized?
      return :skipped_no_date if @transaction.transaction_at.blank?
      return :already_written if WorkbookEntry.exists?(transaction_id: @transaction.id)
      raise ConfigurationError, "hello_smc_spreadsheet_id is not configured" if @spreadsheet_id.blank?

      client = @client || GoogleSheetClient.new(spreadsheet_id: @spreadsheet_id)
      SheetLock.with(@spreadsheet_id) do
        return :already_written if WorkbookEntry.exists?(transaction_id: @transaction.id)

        resolution = Resolver.call(transaction: @transaction)
        resolution.identified? ? write_identified(client, resolution) : write_unidentified(client, resolution)
      end
    end

    private

    def marker
      "TX#{@transaction.id}"
    end

    def write_identified(client, resolution)
      mb_rows = client.values(MB_SHEET, MB_READ_RANGE)
      existing = marker_row(mb_rows, MB_MARKER_COL)
      return reconcile!("identified", resolution, mb_row: existing + 1) if existing

      amount = @transaction.transaction_amount_vnd
      ds_update, ds_cell, ds_sheet = increment_daily(client, resolution.merchant_dealer, amount)
      updates = [ ds_update ]

      mb_row, mb_update = append_mb(client, resolution, mb_rows)
      updates << mb_update

      client.batch_update_values(updates)
      record!(branch: "identified", ds_sheet: ds_sheet, ds_cell: ds_cell, mb_row: mb_row,
              payload: payload(resolution, issue: nil))
      :identified
    rescue CellMissing => error
      write_unidentified(client, resolution, issue: error.message == "ds_cell_not_numeric" ? error.message : "ds_cell_missing")
    end

    def write_unidentified(client, resolution, issue: resolution.issue)
      rows = client.values(UNIDENTIFIED_SHEET, UNIDENTIFIED_READ_RANGE)
      existing = marker_row(rows, UNIDENTIFIED_MARKER_COL)
      return reconcile!("unidentified", resolution, unidentified_row: existing + 1, issue: issue) if existing

      row, update = append_unidentified(client, rows)
      client.batch_update_values([ update ])
      record!(branch: "unidentified", unidentified_row: row, payload: payload(resolution, issue: issue))
      :unidentified
    end

    # The sheet already holds this transaction (an earlier attempt applied the
    # batch but did not finish): record it without touching the sheet again.
    def reconcile!(branch, resolution, issue: nil, **rows)
      record!({ branch: branch, payload: payload(resolution, issue: issue || "reconciled_after_retry") }.merge(rows))
      :already_written
    end

    # --- DS MB T{month} -----------------------------------------------------

    def increment_daily(client, link, amount)
      sheet = monthly_sheet(client)
      grid = client.values(sheet, DS_READ_RANGE)

      header_row, header_col = find_cell(grid) { |value| same_text?(value, link.ds_sheet_anchor) }
      raise CellMissing, "ds_anchor" unless header_row

      agent_col = (header_col..[ header_col + 6, DS_LAST_COL ].min).find do |col|
        same_text?(grid.dig(header_row, col), link.ds_header)
      end
      raise CellMissing, "ds_header" unless agent_col

      date_row = find_date_row(grid, header_row, header_col, @transaction.transaction_at.to_date)
      raise CellMissing, "ds_date" unless date_row

      cell = a1(date_row, agent_col)
      formula = running_sum(client.values(sheet, cell, value_render_option: "FORMULA").dig(0, 0), amount)
      # The day cell holds something the writer cannot add to (a note, another
      # formula): book the bill in "Bill vô chủ" so it is not silently missing
      # from DS MB, like any other DS MB cell that cannot be found.
      raise CellMissing, "ds_cell_not_numeric" unless formula

      [ { sheet: sheet, range: "#{cell}:#{cell}", rows: [ [ formula ] ] }, cell, sheet ]
    end

    # DS MB day cells add up as a formula so every bill stays visible:
    # empty -> "=n", 354367000 -> "=354367000+n", "=a+b" -> "=a+b+n".
    # Any other content (text, a different formula) is not touched.
    def running_sum(current, amount)
      case current
      when nil, "" then "=#{amount}"
      when Integer then "=#{current}+#{amount}"
      when Float then current == current.round ? "=#{current.round}+#{amount}" : nil
      when RUNNING_SUM then "#{current.strip}+#{amount}"
      when /\A\s*\d{1,3}(?:[.,]\d{3})+\s*\z/, /\A\s*\d+\s*\z/ then "=#{current.gsub(/\D/, "")}+#{amount}"
      end
    end

    # Looks for the day only inside this table's contiguous date run, so a
    # missing day never falls through into the table stacked below.
    def find_date_row(grid, header_row, col, target)
      started = false
      ((header_row + 1)...grid.length).each do |row|
        day = date_of(grid.dig(row, col))
        if day
          started = true
          return row if day == target
        elsif started
          break
        end
      end
      nil
    end

    def monthly_sheet(client)
      month = @transaction.transaction_at.in_time_zone.month
      title = "#{DS_PREFIX}#{month}"
      return title if client.titles.include?(title)

      source = client.titles.select { |name| name.start_with?(DS_PREFIX) }
        .max_by { |name| name.delete_prefix(DS_PREFIX).to_i }
      raise CellMissing, "ds_sheet" unless source

      # Build under a temporary name and rename last: the month sheet only
      # appears once it is fully set up, so a failed attempt is simply redone.
      temp = "#{SETUP_PREFIX}#{title}"
      client.delete_sheet(temp) if client.titles.include?(temp)
      client.duplicate_sheet(source_title: source, dest_title: temp)
      client.batch_update_values(month_setup_updates(client, temp))
      client.rename_sheet(from: temp, to: title)
      title
    end

    # Rewrites every date column to the new month and blanks the amount cells
    # that sit under it. Formulas (the Tổng cộng block) are read with
    # FORMULA rendering, arrive as "=..." strings and are never touched.
    # Blanking uses "" because Sheets skips null when writing.
    def month_setup_updates(client, title)
      grid = client.values(title, DS_READ_RANGE, value_render_option: "FORMULA")
      time = @transaction.transaction_at.in_time_zone
      year = time.year
      month = time.month
      days_in_month = Date.new(year, month, -1).day

      runs = date_runs(grid)
      raise CellMissing, "ds_dates" if runs.empty?

      updates = []
      runs.each do |run|
        rows = extend_rows(grid, run, days_in_month)
        dates = rows.each_index.map { |i| [ i < days_in_month ? Date.new(year, month, i + 1).iso8601 : "" ] }
        updates << range_update(title, rows.first, run.col, rows.last, run.col, dates)

        amount_columns(run, runs).each do |col|
          numeric_rows = run.rows.select { |row| amount_cell?(grid.dig(row, col)) }
          consecutive_groups(numeric_rows).each do |group|
            updates << range_update(title, group.first, col, group.last, col, group.map { [ "" ] })
          end
        end
      end
      updates
    end

    # Day amounts: plain numbers or the writer's running sums ("=a+b"), never
    # the SUM formulas of the totals block.
    def amount_cell?(value)
      value.is_a?(Numeric) || (value.is_a?(String) && value.match?(RUNNING_SUM))
    end

    # Columns holding runs of consecutive days (at least MIN_DATE_RUN long).
    def date_runs(grid)
      width = grid.map(&:length).max.to_i
      runs = []
      (0...width).each do |col|
        row = 0
        while row < grid.length
          first = date_of(grid.dig(row, col))
          unless first
            row += 1
            next
          end

          last = row
          previous = first
          while (candidate = date_of(grid.dig(last + 1, col))) && candidate == previous + 1
            previous = candidate
            last += 1
          end
          runs << DateRun.new(col, row..last) if last - row + 1 >= MIN_DATE_RUN
          row = last + 1
        end
      end
      runs
    end

    # A month sheet cloned from a shorter month has blank rows under the
    # table; reuse them so a 31-day month still gets all its days.
    def extend_rows(grid, run, days_in_month)
      rows = run.rows.to_a
      while rows.length < days_in_month && blank_cell?(grid.dig(rows.last + 1, run.col))
        rows << rows.last + 1
      end
      rows
    end

    def amount_columns(run, runs)
      limit = [ run.col + 6, DS_LAST_COL ].min
      next_run_col = runs.select do |other|
        other.col > run.col && other.rows.begin <= run.rows.end && other.rows.end >= run.rows.begin
      end.map(&:col).min
      limit = [ limit, next_run_col - 1 ].min if next_run_col
      ((run.col + 1)..limit).to_a
    end

    def consecutive_groups(rows)
      rows.slice_when { |a, b| b != a + 1 }.to_a
    end

    def range_update(sheet, row1, col1, row2, col2, rows)
      { sheet: sheet, range: "#{a1(row1, col1)}:#{a1(row2, col2)}", rows: rows }
    end

    # --- MB and Bill vô chủ ledgers ----------------------------------------

    def append_mb(client, resolution, rows)
      index = first_blank_row_index(rows)
      n = index + 1
      client.ensure_rows(MB_SHEET, n) if index >= rows.length

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
        date_text("%d/%m/%Y"),
        date_text("%H:%M:%S"),
        text_cell(resolution.merchant_dealer.dealer.name),
        text_cell(resolution.merchant.name),
        nil, # K "Người đi tiền": not part of a transaction any more
        marker
      ] ]
      [ n, { sheet: MB_SHEET, range: "A#{n}:L#{n}", rows: values } ]
    end

    def append_unidentified(client, rows)
      index = first_blank_row_index(rows)
      n = index + 1
      client.ensure_rows(UNIDENTIFIED_SHEET, n) if index >= rows.length

      rate = @transaction.base_fee_rate_used || BigDecimal("0.0088")
      status = (@transaction.approved? || @transaction.exported?) ? "Thành công" : "Cần kiểm tra"
      values = [ [
        text_cell(@transaction.raw_merchant_name.presence || "—"),
        "=C#{n}-(C#{n}*D#{n})",
        @transaction.transaction_amount_vnd,
        rate&.to_f,
        date_text("%d/%m/%Y %H:%M:%S"),
        status,
        marker
      ] ]
      [ n, { sheet: UNIDENTIFIED_SHEET, range: "A#{n}:G#{n}", rows: values } ]
    end

    # First row (after the header) whose column A is empty. Works on the 2-D
    # rows exactly as the API returns them: an empty row may come back as
    # [], [""] or [nil], and trailing empty rows are omitted.
    def first_blank_row_index(rows)
      found = (1...rows.length).find { |i| blank_cell?(Array(rows[i])[0]) }
      found || [ rows.length, 1 ].max
    end

    def marker_row(rows, col)
      rows.index { |row| Array(row)[col].to_s == marker }
    end

    # --- persistence --------------------------------------------------------

    def record!(attrs)
      WorkbookEntry.create!(
        {
          recorded_transaction: @transaction,
          spreadsheet_id: @spreadsheet_id,
          amount_vnd: @transaction.transaction_amount_vnd
        }.merge(attrs)
      )
    end

    def payload(resolution, issue:)
      {
        "merchant_id" => resolution.merchant&.id,
        "dealer_id" => resolution.merchant_dealer&.dealer_id,
        "tid_key" => resolution.merchant_dealer&.tid_key,
        "issue" => issue,
        "transaction_date" => @transaction.transaction_at&.to_date&.iso8601
      }.compact
    end

    # --- cell helpers -------------------------------------------------------

    def find_cell(grid)
      grid.each_with_index do |row, r|
        row.each_with_index do |value, c|
          return [ r, c ] if yield(value)
        end
      end
      [ nil, nil ]
    end

    # Dates in the ledgers are literal text (dd/mm/yyyy): the MB date/time
    # columns are number-formatted and Bill vô chủ already stores text, and a
    # leading apostrophe stops Sheets from parsing by the sheet's locale.
    def date_text(format)
      "'#{@transaction.transaction_at.in_time_zone.strftime(format)}"
    end

    # Dates come back as Excel serial numbers (UNFORMATTED_VALUE / FORMULA);
    # ISO strings are accepted too so month-rollover dates round-trip.
    def date_of(value)
      case value
      when Date then value
      when Time, DateTime then value.to_date
      when Numeric
        serial = value.to_i
        return nil unless DATE_SERIAL_RANGE.cover?(serial)

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
  end
end
