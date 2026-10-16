module Workbook
  # Writes one transaction into the live Hello SMC Google Sheet.
  #
  # Every cell of one transaction goes out in a single values.batchUpdate, so a
  # partial write cannot leave the sheet half-updated. Writes are serialized per
  # spreadsheet with a session-level Postgres advisory lock (try-lock: a busy
  # lock raises LockBusy and the job retries, so Sidekiq threads never block).
  #
  # Idempotency: every MB row carries a "TX<id>" marker (column L). A retry
  # after an ambiguous failure (timeout after Google applied the batch, crash
  # before the DB entry was saved) finds the marker and only records the entry
  # instead of adding the amount twice.
  #
  # A bill the writer cannot place (unknown HKD, agent or TID, a DS MB cell it
  # cannot find or add to, a header naming someone it cannot match) is not
  # written anywhere: it goes back to the review queue with the reason. Once
  # the configuration or the sheet is fixed, approving it again writes it.
  #
  # Remitters are not part of a transaction: the "thu chi" tab is written from
  # RemitterTransfer (Workbook::RemitterReportWriter), and MB column K
  # ("Người đi tiền") is left empty.
  class HelloSmcWriter
    include SheetText

    DS_PREFIX = "DS MB T"
    SETUP_PREFIX = "__setup_"
    MB_SHEET = "MB"

    DS_READ_RANGE = "A1:X80"
    DS_LAST_COL = 23
    # A DS MB day cell the writer keeps as a running sum: "=354367000+486000".
    RUNNING_SUM = /\A=\s*-?\d+(?:\s*[+-]\s*\d+)*\s*\z/
    # Whole-column reads return only the used rows, so the ledgers can grow.
    MB_READ_RANGE = "A:L"
    MB_MARKER_COL = 11

    # Serial numbers for 2000-01-01..2099-12-31; keeps small amounts from
    # being mistaken for dates.
    DATE_SERIAL_RANGE = (36_526..73_415)
    MIN_DATE_RUN = 5

    UNMATCHED = "ds_header_dealer_unmatched".freeze
    REASSIGN_FAILED = "dealer_reassign_failed".freeze
    PAID_BY_QR = "payment_qr_confirmed".freeze
    KEPT_ISSUES = [ "ds_cell_not_numeric", UNMATCHED, REASSIGN_FAILED, PAID_BY_QR ].freeze
    # Reasons fixed on the HKD's agent rows: the review page links to them.
    MAPPING_ISSUES = [ "agent_tid_missing", "agent_tid_unmapped", "agent_recipient_mismatch", "ds_cell_missing",
                       UNMATCHED, REASSIGN_FAILED ].freeze

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
      # Hold the same row lock as review decisions until the external write
      # and its local receipt finish. A queued job must use current values.
      @transaction.with_lock { write_locked }
    end

    private

    def write_locked
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
        resolution.identified? ? write_identified(client, resolution) : send_to_review(resolution.issue)
      end
    end

    def marker
      "TX#{@transaction.id}"
    end

    def write_identified(client, resolution)
      mb_rows = client.values(MB_SHEET, MB_READ_RANGE)
      existing = marker_row(mb_rows, MB_MARKER_COL)
      return reconcile!("identified", resolution, mb_row: existing + 1) if existing

      link = resolution.merchant_dealer
      reassign_to!(link.dealer) unless dealer_current?(link)

      amount = @transaction.transaction_amount_vnd
      ds_update, ds_cell, ds_sheet, header_change = increment_daily(client, link, amount)
      updates = [ ds_update ]

      mb_row, mb_update = append_mb(client, resolution, mb_rows)
      updates << mb_update

      client.batch_update_values(updates)
      record!(branch: "identified", ds_sheet: ds_sheet, ds_cell: ds_cell, mb_row: mb_row,
              payload: payload(resolution, issue: nil))
      remember_header(link, header_change, ds_sheet)
      :identified
    rescue CellMissing => error
      send_to_review(issue_for(error))
    end

    # Nothing was written: the bill goes back to the review queue with this
    # reason only (the earlier review reasons were settled when it was approved).
    # Leaving "approved" also invalidates a prepared payment QR.
    def send_to_review(issue)
      before = @transaction.audit_snapshot
      @transaction.source_data = @transaction.source_data.merge(
        "review_reasons" => [ issue ], "workbook_review" => { "issue" => issue, "at" => Time.current.utc.iso8601 }
      )
      @transaction.transition_to!("needs_review")
      @transaction.reviews.open.find_each { |review| review.update!(status: "superseded") }
      @transaction.reviews.create!(status: "open", reason_codes: [ issue ], reason: issue, original_values: {})
      AuditLogger.log!(action: "transaction.sent_to_review", auditable: @transaction, before_data: before,
                       after_data: @transaction.audit_snapshot, metadata: { "issue" => issue })
      :needs_review
    end

    # Moves the bill to the dealer that now holds its agent row. A confirmed
    # payment QR may already have paid the previous dealer: the bill goes to
    # review once, and when a person approves it again it keeps its dealer.
    def reassign_to!(dealer)
      return if @transaction.source_data.dig("workbook_review", "issue") == PAID_BY_QR

      reassigned = Transactions::DealerReassigner.call(transaction: @transaction, dealer: dealer, source: "writer")
      return if reassigned.success?

      raise CellMissing, reassigned.reason == PAID_BY_QR ? PAID_BY_QR : REASSIGN_FAILED
    end

    # Issues kept as they are; any other missing cell (anchor, header, date) is ds_cell_missing.
    def issue_for(error)
      error.message.in?(KEPT_ISSUES) ? error.message : "ds_cell_missing"
    end

    # The bill was evaluated for the dealer that held this agent row then. When
    # the row changed hands since (the DS MB header named another person), the
    # bill moves to the new dealer before it is written. A dealer a person chose
    # in review is never replaced (corrections by the system have no "by").
    def dealer_current?(link)
      return true if @transaction.dealer_id.blank? || @transaction.dealer_id == link.dealer_id
      return true unless @transaction.source_data.dig("dealer_resolution", "merchant_dealer_id") == link.id

      Array(@transaction.source_data["manual_corrections"]).any? do |entry|
        entry["by"].present? && Array(entry["fields"]).include?("dealer_id")
      end
    end

    # The header text of the same person changed: remember it once the bill is
    # in the sheet. A failure here only logs; the bill is already recorded.
    def remember_header(link, change, sheet)
      return unless change&.kind.in?(%i[same rename])

      MerchantDealer.transaction(requires_new: true) do
        DsHeaderChange.rename!(link: link, header: change.header, sheet: sheet, source: "writer", transaction: @transaction)
      end
    rescue StandardError => error
      StructuredLog.warn("workbook.ds_header_not_saved", transaction_id: @transaction.id,
                                                          merchant_dealer_id: link.id, error: error.class.name)
    end

    # The header changed since the agent row was set up. Another existing
    # dealer takes the row (and this bill) when the switch is on; a new or
    # unclear name sends the bill back to review so no money goes to a guess.
    def adopt_header_change!(link, change, sheet)
      case change.kind
      when :switch
        raise CellMissing, UNMATCHED unless AppConfig.ds_header_auto_switch?
        raise CellMissing, UNMATCHED unless DsHeaderChange.switch!(link: link, dealer: change.dealer, header: change.header,
                                                                   sheet: sheet, source: "writer", transaction: @transaction)

        reassign_to!(change.dealer)
      when :unmatched
        raise CellMissing, UNMATCHED
      end
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

      location = DsHeaderMatcher.locate(grid: grid, link: link, last_col: DS_LAST_COL)
      raise CellMissing, "ds_anchor" unless location
      raise CellMissing, "ds_header" unless location.col

      header_row, header_col, agent_col = location.header_row, location.anchor_col, location.col

      date_row = find_date_row(grid, header_row, header_col, @transaction.transaction_at.to_date)
      raise CellMissing, "ds_date" unless date_row

      cell = a1(date_row, agent_col)
      formula = running_sum(client.values(sheet, cell, value_render_option: "FORMULA").dig(0, 0), amount)
      # The day cell holds something the writer cannot add to (a note, another
      # formula): the bill goes back to review instead of silently missing from
      # DS MB, like any other DS MB cell that cannot be found.
      raise CellMissing, "ds_cell_not_numeric" unless formula

      # The database changes only once the bill is sure to land in that cell.
      adopt_header_change!(link, location.change, sheet) if location.change
      [ { sheet: sheet, range: "#{cell}:#{cell}", rows: [ [ formula ] ] }, cell, sheet, location.change ]
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

    # --- MB ledger ----------------------------------------------------------

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
        "'#{@transaction.lot_number}",
        date_text("%d/%m/%Y"),
        date_text("%H:%M:%S"),
        text_cell(resolution.merchant_dealer.dealer.name),
        text_cell(resolution.merchant.name),
        nil, # K "Người đi tiền": not part of a transaction any more
        marker
      ] ]
      [ n, { sheet: MB_SHEET, range: "A#{n}:L#{n}", rows: values } ]
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

    # Dates in the ledger are literal text (dd/mm/yyyy): the MB date/time
    # columns are number-formatted, and a leading apostrophe stops Sheets from
    # parsing by the sheet's locale.
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
