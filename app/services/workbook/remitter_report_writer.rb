module Workbook
  # Writes one approved RemitterTransfer into the day's "thu chi {ngày}{tháng}"
  # tab of the Hello SMC sheet.
  #
  # Tab layout: header row 2 repeats the remitter names per block
  # ("LẬP KIM AN …"); each block's agent label sits in the blank column before
  # them; an agent has a label row, entry rows and a TOTAL row (=SUM per
  # remitter column). Blocks sit side by side in bands and share their rows.
  #
  # Every transfer adds one sheet row inside the agent's block, just above its
  # last entry row, and puts the amount in the remitter's column. A whole row is
  # inserted (not only the block's columns) so the blocks of the band stay
  # aligned and the manual cash book below moves as one piece. Inserting inside
  # the SUM ranges lets Sheets grow them; any TOTAL in that row that still stops
  # short is extended afterwards.
  #
  # Idempotent: the amount cell gets the note "RT<id>" in the same request as
  # the insert, so a retry after an ambiguous failure finds it and does not add
  # a second row.
  class RemitterReportWriter
    include SheetText

    SHEET_PREFIX = "thu chi"
    # Whole columns return only the used cells, so any number of remitter
    # columns per block (and extra rows) is read without a fixed width.
    READ_RANGE = "A:AZ"
    LAST_COL_LETTER = "AZ"
    SUM_RANGE = /\A=\s*sum\(\s*(\$?)([A-Z]{1,3})(\$?)(\d+)\s*:\s*(\$?)([A-Z]{1,3})(\$?)(\d+)\s*\)\s*\z/i

    ConfigurationError = HelloSmcWriter::ConfigurationError

    def self.call(remitter_transfer:, client: nil, spreadsheet_id: AppConfig.hello_smc_spreadsheet_id)
      new(remitter_transfer: remitter_transfer, client: client, spreadsheet_id: spreadsheet_id).call
    end

    def initialize(remitter_transfer:, client:, spreadsheet_id:)
      @transfer = remitter_transfer
      @client = client
      @spreadsheet_id = spreadsheet_id
    end

    def call
      return :already_written if @transfer.written?
      return :skipped_not_approved unless @transfer.writable?
      raise ConfigurationError, "hello_smc_spreadsheet_id is not configured" if @spreadsheet_id.blank?

      client = @client || GoogleSheetClient.new(spreadsheet_id: @spreadsheet_id)
      SheetLock.with(@spreadsheet_id) do
        return :already_written if @transfer.reload.written?

        write(client)
      end
    end

    private

    def write(client)
      title = sheet_title(client)
      return issue!("rd_sheet_missing") unless title

      grid = read_grid(client, title)
      label = @transfer.merchant_dealer.rd_agent_label
      block_row, block_col = find_agent(grid, label)
      return issue!("rd_agent_missing", title) unless block_row

      excel_key = @transfer.remitter.excel_key
      remitter_col = remitter_column(grid, block_col, excel_key)
      if remitter_col.nil? && insert_remitter_columns(client, title, grid, excel_key)
        # Columns moved: read the tab again and locate everything afresh.
        grid = read_grid(client, title)
        block_row, block_col = find_agent(grid, label)
        remitter_col = block_row && remitter_column(grid, block_col, excel_key)
      end
      return issue!("rd_remitter_missing", title) unless remitter_col

      total_row = total_row(grid, block_row, block_col)
      return issue!("rd_total_missing", title) unless total_row

      existing = marked_row(client, title, block_row, total_row, remitter_col)
      if existing
        fixes = extend_totals(client, title, grid, total_row, existing)
        return record!(title, existing, remitter_col, fixes, reconciled: true)
      end

      # Above the last entry row keeps the new row inside every SUM range; a
      # block with only its label row gets the row just under the label.
      row = [ total_row - 1, block_row + 1 ].max
      client.insert_row_with_value(title, row: row, col: remitter_col, value: @transfer.amount_vnd,
                                          note: "#{@transfer.marker} +#{@transfer.amount_vnd}")
      fixes = extend_totals(client, title, grid, total_row + 1, row)
      record!(title, row, remitter_col, fixes)
    end

    def sheet_title(client)
      time = @transfer.transferred_at.in_time_zone
      wanted = "#{SHEET_PREFIX} #{time.day}#{time.month}"
      client.titles.find { |title| same_text?(title, wanted) }
    end

    def read_grid(client, title)
      grid = client.values(title, READ_RANGE)
      grid.first(stop_row(grid))
    end

    # The bottom accounting area (SP in / MB in / TOTAL AMOUNT …) is manual and
    # may repeat agent or remitter names; stop reading blocks above it.
    def stop_row(grid)
      stop = grid.each_with_index.find do |row, index|
        next false if index < 2

        Array(row).any? { |cell| normalize_text(cell).start_with?("total amount") } ||
          %w[sp\ in mb\ in].include?(normalize_text(Array(row)[0]))
      end
      stop ? stop[1] : grid.length
    end

    # Columns that hold an agent label: blank in header row 2, followed by a
    # remitter name.
    def block_columns(grid)
      header = Array(grid[1])
      (0...header.length).select { |col| blank_cell?(header[col]) && !blank_cell?(header[col + 1]) }
    end

    def find_agent(grid, label)
      columns = block_columns(grid)
      (2...grid.length).each do |row|
        columns.each do |col|
          return [ row, col ] if agent_label?(Array(grid[row])[col], label)
        end
      end
      [ nil, nil ]
    end

    # Remitter columns follow the label column up to the first blank header cell.
    def remitter_column(grid, agent_col, excel_key)
      header = Array(grid[1])
      col = agent_col + 1
      while col < header.length && !blank_cell?(header[col])
        return col if same_text?(header[col], excel_key)

        col += 1
      end
      nil
    end

    def last_remitter_column(grid, block_col)
      header = Array(grid[1])
      col = block_col + 1
      col += 1 while col + 1 < header.length && !blank_cell?(header[col + 1])
      col
    end

    def total_row(grid, block_row, block_col)
      ((block_row + 1)...grid.length).find { |row| normalize_text(Array(grid[row])[block_col]) == "total" }
    end

    # A remitter with no column yet (new person in admin): add one at the end of
    # every block that lacks it, in the header row 2 and with the neighbour's
    # TOTAL formulas shifted by one column. Blocks are handled right to left so
    # the columns of the blocks still to do do not move. Only the block rows are
    # shifted, never the manual accounting area below. Safe to retry: once the
    # header exists nothing is inserted again.
    def insert_remitter_columns(client, title, grid, excel_key)
      stop = grid.length
      targets = block_columns(grid).reject { |col| remitter_column(grid, col, excel_key) }.sort.reverse
      return false if targets.empty?

      formulas = client.values(title, READ_RANGE, value_render_option: "FORMULA")
      min_cols = grid.map(&:length).max.to_i + targets.size + 1
      targets.each do |block_col|
        last = last_remitter_column(grid, block_col)
        new_col = last + 1
        client.insert_columns(title, col: new_col, end_row: stop, min_cols: min_cols)
        updates = [ { sheet: title, range: a1(1, new_col), rows: [ [ text_cell(excel_key) ] ] } ]
        (2...stop).each do |row|
          next unless normalize_text(Array(grid[row])[block_col]) == "total"

          formula = Array(formulas[row])[last]
          next unless formula.is_a?(String) && formula.start_with?("=")

          updates << { sheet: title, range: a1(row, new_col), rows: [ [ shift_formula_columns(formula, 1) ] ] }
        end
        client.batch_update_values(updates)
      end
      true
    end

    # Row (0-based) of the block whose remitter cell carries this transfer's note.
    def marked_row(client, title, block_row, total_row, col)
      notes = client.notes(title, "#{a1(block_row, col)}:#{a1(total_row + 1, col)}")
      offset = notes.index { |row| Array(row).first.to_s.split(/\s+/).include?(@transfer.marker) }
      offset && block_row + offset
    end

    # Every TOTAL of the band (same sheet row) that sums a single column and
    # stops right above the new row is extended to include it. Formulas Sheets
    # already grew, or that are not a plain SUM(col:col), are left alone.
    def extend_totals(client, title, grid, total_row, new_row)
      formulas = Array(client.values(title, "A#{total_row + 1}:#{LAST_COL_LETTER}#{total_row + 1}",
                                     value_render_option: "FORMULA").first)
      block_cols = block_columns(grid).select { |col| normalize_text(formulas[col]) == "total" }
      fixes = []
      unparsed = []
      block_cols.each do |block_col|
        ((block_col + 1)..last_remitter_column(grid, block_col)).each do |col|
          formula = formulas[col]
          next unless formula.is_a?(String) && formula.start_with?("=")

          match = formula.match(SUM_RANGE)
          unless match && match[2].casecmp?(match[6])
            unparsed << a1(total_row, col)
            next
          end
          first, last = match[4].to_i, match[8].to_i # 1-based sheet rows
          row_above_new = new_row     # new_row is 0-based, so this is the 1-based row above it
          new_row_number = new_row + 1 # 1-based number of the inserted row
          next unless last == row_above_new && first <= row_above_new

          fixed = "=SUM(#{match[1]}#{match[2]}#{match[3]}#{first}:#{match[5]}#{match[6]}#{match[7]}#{new_row_number})"
          fixes << { sheet: title, range: a1(total_row, col), rows: [ [ fixed ] ] }
        end
      end
      client.batch_update_values(fixes) if fixes.any?
      { fixed: fixes.map { |fix| fix[:range] }, unparsed: unparsed }
    end

    def record!(title, row, col, fixes, reconciled: false)
      @transfer.update!(
        written_at: Time.current, rd_sheet: title, rd_row: row + 1, rd_cell: a1(row, col),
        metadata: @transfer.metadata.except("write_issue").merge(
          "total_fixed" => fixes[:fixed], "total_unparsed" => fixes[:unparsed], "reconciled" => reconciled
        ).compact_blank
      )
      AuditLogger.log!(action: "remitter_transfer.written", auditable: @transfer,
                       metadata: { "sheet" => title, "cell" => a1(row, col) })
      reconciled ? :already_written : :written
    end

    def issue!(code, title = nil)
      @transfer.update!(metadata: @transfer.metadata.merge("write_issue" => code, "write_sheet" => title).compact)
      code.to_sym
    end
  end
end
