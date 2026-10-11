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
  class HelloSmcWriter
    DS_PREFIX = "DS MB T"
    SETUP_PREFIX = "__setup_"
    # One tab per day: "thu chi 1010" = 10 Oct, "thu chi 910" = 9 Oct.
    RD_SHEET_PREFIX = "thu chi"
    MB_SHEET = "MB"
    UNIDENTIFIED_SHEET = "Bill vô chủ"

    DS_READ_RANGE = "A1:X80"
    DS_LAST_COL = 23
    # Whole columns return only the used cells, so any number of remitter
    # columns per block (and extra rows) is read without a fixed width.
    RD_READ_RANGE = "A:AZ"
    CHANNEL_SUFFIX = /(?:\s+(?:mb|sp|qr))+\z/
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
    RdTarget = Struct.new(:update, :cell, :sheet, :issue)

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
      with_advisory_lock do
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

      rd = resolution.remitter ? increment_remitter(client, resolution, amount) : nil
      updates << rd.update if rd&.update

      mb_row, mb_update = append_mb(client, resolution, mb_rows)
      updates << mb_update

      client.batch_update_values(updates)
      record!(branch: "identified", ds_sheet: ds_sheet, ds_cell: ds_cell, rd_cell: rd&.cell, mb_row: mb_row,
              payload: payload(resolution, issue: rd&.issue, rd_sheet: rd&.sheet))
      :identified
    rescue CellMissing
      write_unidentified(client, resolution, issue: "ds_cell_missing")
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

      current = numeric(grid.dig(date_row, agent_col))
      cell = a1(date_row, agent_col)
      [ { sheet: sheet, range: "#{cell}:#{cell}", rows: [ [ current + amount ] ] }, cell, sheet ]
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
          numeric_rows = run.rows.select { |row| grid.dig(row, col).is_a?(Numeric) }
          consecutive_groups(numeric_rows).each do |group|
            updates << range_update(title, group.first, col, group.last, col, group.map { [ "" ] })
          end
        end
      end
      updates
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

    # --- thu chi {ngày}{tháng} (remitter report) ----------------------------
    #
    # One tab per day. Header row 2 repeats the remitter names per block
    # ("LẬP KIM AN …"); each block's label sits in the blank column before them.
    # An agent has a label row, more entry rows, a spacer and a TOTAL row. The
    # amount goes into the first free cell of the remitter's column, like the
    # hand-typed rows. Anything that cannot be placed safely is skipped with an
    # issue code; DS MB and MB are still written.

    def increment_remitter(client, resolution, amount)
      title = rd_sheet_title(client)
      return RdTarget.new(nil, nil, nil, "rd_sheet_missing") unless title

      grid = client.values(title, RD_READ_RANGE)
      grid = grid.first(rd_stop_row(grid))
      label = resolution.merchant_dealer.rd_agent_label
      block_row, block_col = rd_find_agent(grid, label)
      return RdTarget.new(nil, nil, title, "rd_agent_missing") unless block_row

      excel_key = resolution.remitter.excel_key
      remitter_col = rd_remitter_column(grid, block_col, excel_key)
      if remitter_col.nil? && rd_insert_remitter_columns(client, title, grid, excel_key)
        # Columns moved: read the tab again and locate everything afresh.
        grid = client.values(title, RD_READ_RANGE)
        grid = grid.first(rd_stop_row(grid))
        block_row, block_col = rd_find_agent(grid, label)
        remitter_col = block_row && rd_remitter_column(grid, block_col, excel_key)
      end
      return RdTarget.new(nil, nil, title, "rd_remitter_missing") unless remitter_col

      total_row = rd_total_row(grid, block_row, block_col)
      return RdTarget.new(nil, nil, title, "rd_total_missing") unless total_row

      row = rd_first_free_row(grid, block_row, total_row, block_col, remitter_col)
      return RdTarget.new(nil, nil, title, "rd_block_full") unless row

      cell = a1(row, remitter_col)
      RdTarget.new({ sheet: title, range: "#{cell}:#{cell}", rows: [ [ amount ] ] }, cell, title, nil)
    end

    def rd_sheet_title(client)
      time = @transaction.transaction_at.in_time_zone
      wanted = "#{RD_SHEET_PREFIX} #{time.day}#{time.month}"
      client.titles.find { |title| same_text?(title, wanted) }
    end

    # The bottom accounting area (SP in / MB in / TOTAL AMOUNT …) is manual and
    # may repeat agent or remitter names; stop reading blocks above it.
    def rd_stop_row(grid)
      stop = grid.each_with_index.find do |row, index|
        next false if index < 2

        Array(row).any? { |cell| normalize_text(cell).start_with?("total amount") } ||
          %w[sp\ in mb\ in].include?(normalize_text(Array(row)[0]))
      end
      stop ? stop[1] : grid.length
    end

    # Columns that hold an agent label: blank in header row 2, followed by a
    # remitter name.
    def rd_block_columns(grid)
      header = Array(grid[1])
      (0...header.length).select { |col| blank_cell?(header[col]) && !blank_cell?(header[col + 1]) }
    end

    def rd_find_agent(grid, label)
      columns = rd_block_columns(grid)
      (2...grid.length).each do |row|
        columns.each do |col|
          return [ row, col ] if agent_label?(Array(grid[row])[col], label)
        end
      end
      [ nil, nil ]
    end

    # Remitter columns follow the label column up to the first blank header cell.
    def rd_remitter_column(grid, agent_col, excel_key)
      header = Array(grid[1])
      col = agent_col + 1
      while col < header.length && !blank_cell?(header[col])
        return col if same_text?(header[col], excel_key)

        col += 1
      end
      nil
    end

    # A remitter with no column yet (new person in admin): add one at the end of
    # every block that lacks it, in the header row 2 and with the neighbour's
    # TOTAL formulas shifted by one column. Blocks are handled right to left so
    # the columns of the blocks still to do do not move. Only the block rows are
    # shifted, never the manual accounting area below. Safe to retry: once the
    # header exists nothing is inserted again.
    def rd_insert_remitter_columns(client, title, grid, excel_key)
      stop_row = grid.length
      targets = rd_block_columns(grid).reject { |col| rd_remitter_column(grid, col, excel_key) }.sort.reverse
      return false if targets.empty?

      formulas = client.values(title, RD_READ_RANGE, value_render_option: "FORMULA")
      min_cols = grid.map(&:length).max.to_i + targets.size + 1
      targets.each do |block_col|
        last = rd_last_remitter_column(grid, block_col)
        new_col = last + 1
        client.insert_columns(title, col: new_col, end_row: stop_row, min_cols: min_cols)
        updates = [ { sheet: title, range: a1(1, new_col), rows: [ [ text_cell(excel_key) ] ] } ]
        (2...stop_row).each do |row|
          next unless normalize_text(Array(grid[row])[block_col]) == "total"

          formula = Array(formulas[row])[last]
          next unless formula.is_a?(String) && formula.start_with?("=")

          updates << { sheet: title, range: a1(row, new_col), rows: [ [ shift_formula_columns(formula, 1) ] ] }
        end
        client.batch_update_values(updates)
      end
      true
    end

    def rd_last_remitter_column(grid, block_col)
      header = Array(grid[1])
      col = block_col + 1
      col += 1 while col + 1 < header.length && !blank_cell?(header[col + 1])
      col
    end

    # "=SUM(F8:F12)" -> "=SUM(G8:G12)". Absolute columns ($F) and other-sheet
    # references stay as they are.
    def shift_formula_columns(formula, by)
      formula.gsub(/(?<![A-Za-z0-9_$!'])(\$?)([A-Z]{1,3})(\$?)(\d+)(?![\d(A-Za-z])/) do
        absolute, letters, row_mark, row = Regexp.last_match.captures
        next Regexp.last_match[0] if absolute == "$"

        "#{col_letters(letters_to_col(letters) + by)}#{row_mark}#{row}"
      end
    end

    def letters_to_col(letters)
      letters.each_char.reduce(0) { |sum, char| sum * 26 + (char.ord - 64) } - 1
    end

    def col_letters(col)
      letters = ""
      n = col + 1
      while n.positive?
        n, rem = (n - 1).divmod(26)
        letters = (65 + rem).chr + letters
      end
      letters
    end

    def rd_total_row(grid, block_row, block_col)
      ((block_row + 1)...grid.length).find { |row| normalize_text(Array(grid[row])[block_col]) == "total" }
    end

    # The row right above TOTAL is a spacer in the template. Whether the SUM
    # covers it is unknown, so it is never written to.
    def rd_first_free_row(grid, block_row, total_row, block_col, remitter_col)
      last = total_row - 1
      last -= 1 if last > block_row && Array(grid[last])[block_col..remitter_col].to_a.all? { |cell| blank_cell?(cell) }
      (block_row..last).find { |row| blank_cell?(Array(grid[row])[remitter_col]) }
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
        text_cell(resolution.remitter&.name),
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

    def payload(resolution, issue:, rd_sheet: nil)
      {
        "merchant_id" => resolution.merchant&.id,
        "dealer_id" => resolution.merchant_dealer&.dealer_id,
        "tid_key" => resolution.merchant_dealer&.tid_key,
        "remitter_id" => resolution.remitter&.id,
        "issue" => issue,
        "rd_sheet" => rd_sheet,
        "transaction_date" => @transaction.transaction_at&.to_date&.iso8601
      }.compact
    end

    def with_advisory_lock
      key = "hello-smc-workbook:#{@spreadsheet_id}"
      connection = Transaction.connection
      acquired = connection.select_value(
        Transaction.sanitize_sql_array([ "SELECT pg_try_advisory_lock(hashtext(?))", key ])
      )
      raise LockBusy, "workbook write in progress for #{@spreadsheet_id}" unless acquired == true || acquired == "t"

      begin
        yield
      ensure
        begin
          connection.execute(Transaction.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtext(?))", key ]))
        rescue StandardError => error
          Rails.logger.warn("workbook advisory unlock failed: #{error.message}")
        end
      end
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

    def same_text?(left, right)
      normalize_text(left) == normalize_text(right)
    end

    # Diacritic/space-insensitive, and "tid 1" == "tid1" == "TID 1".
    def normalize_text(text)
      VietnameseText.normalize(text).gsub(/\btid\s+(\d+)\b/i, 'tid\1')
    end

    # Agent labels in the report are free text: "Hồng⏎(MB⏎SP⏎QR", "Mến ( MB )",
    # "HảiHN QR", "Lập ⏎(MB+SP+QR". Compare only the name: drop the channel in
    # parentheses or trailing MB/SP/QR, diacritics, case and spaces.
    def agent_label?(cell, label)
      label_key(cell.to_s.split("\n").first) == label_key(label)
    end

    def label_key(text)
      normalize_text(text.to_s.sub(/\(.*\z/, "")).sub(CHANNEL_SUFFIX, "").delete(" ")
    end

    def blank_cell?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def numeric(value)
      case value
      when Numeric then value
      when String then value.gsub(/[^\d.-]/, "").to_f
      else 0
      end
    end

    # OCR/admin text is written with USER_ENTERED so formulas work; a leading
    # = + - @ would be run as a formula, so force it to literal text.
    def text_cell(value)
      text = value.to_s
      text.match?(/\A[=+\-@\t\r]/) ? "'#{text}" : text
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
