module Workbook
  # The clean "thu chi mẫu" tab and the day tabs made from it.
  #
  # A day's "thu chi {ngày}{tháng}" tab is a copy of the template with the day's
  # transfers inserted by RemitterReportWriter. The template is built once from
  # an existing day tab: only what the system writes is cleared (the amounts of
  # the entry rows inside each agent block, and the "RT<id>" notes that mark
  # them). Everything else is kept as it is: headers, agent labels, TOTAL
  # formulas, the amount typed on a label row, and the manual accounting area
  # at the bottom, which the person maintaining the sheet resets by hand.
  class ThuChiTemplate
    include SheetText

    class Error < StandardError; end

    TITLE = "thu chi mẫu"
    SETUP_TITLE = "đang tạo thu chi"
    DAY_TAB = /\Athu chi \d{3,4}\z/i
    READ_RANGE = "A:AZ"
    MARKER = /\bRT\d+\b/

    Report = Data.define(:title, :source, :amounts_cleared, :notes_cleared)

    def self.build!(client:, source: nil)
      new(client).build!(source)
    end

    # A day tab made from the template, put first among the day tabs (newest on
    # the left). Returns its title, or nil when there is no template.
    def self.instantiate!(client:, title:)
      new(client).instantiate!(title)
    end

    def initialize(client)
      @client = client
    end

    def build!(source)
      raise Error, "Đã có tab #{TITLE}." if titles.include?(TITLE)

      source ||= titles.find { |title| title.match?(DAY_TAB) }
      raise Error, "Chưa có tab thu chi nào để làm mẫu." unless source && titles.include?(source)

      # Built under another name and renamed last: the template only appears
      # once it is clean, so a failed run leaves nothing half done.
      @client.delete_sheet(SETUP_TITLE) if titles.include?(SETUP_TITLE)
      @client.duplicate_sheet(source_title: source, dest_title: SETUP_TITLE, index: titles.index(source))
      amounts, notes = clean(SETUP_TITLE)
      @client.rename_sheet(from: SETUP_TITLE, to: TITLE)
      Report.new(title: TITLE, source: source, amounts_cleared: amounts, notes_cleared: notes)
    rescue StandardError
      @client.delete_sheet(SETUP_TITLE) if titles.include?(SETUP_TITLE)
      raise
    end

    def instantiate!(title)
      return nil unless titles.include?(TITLE)

      @client.delete_sheet(SETUP_TITLE) if titles.include?(SETUP_TITLE)
      index = titles.index { |name| name.match?(DAY_TAB) } || titles.size
      @client.duplicate_sheet(source_title: TITLE, dest_title: SETUP_TITLE, index: index)
      @client.rename_sheet(from: SETUP_TITLE, to: title)
      title
    end

    private

    # Always the live list: duplicating and renaming change it.
    def titles
      @client.titles
    end

    def clean(title)
      grid = @client.values(title, READ_RANGE, value_render_option: "FORMULA")
      amounts = amount_cells(grid)
      marked = marked_cells(title, grid)
      @client.batch_update_values(amounts.map { |row, col| { sheet: title, range: a1(row, col), rows: [ [ "" ] ] } }) if amounts.any?
      @client.clear_notes(title, marked)

      grid = @client.values(title, READ_RANGE, value_render_option: "FORMULA")
      raise Error, "Tab mẫu còn số tiền chưa xoá." if amount_cells(grid).any?
      raise Error, "Tab mẫu còn ghi chú RT chưa xoá." if marked_cells(title, grid).any?

      [ amounts.size, marked.size ]
    end

    # The typed amounts of the entry rows: the rows between an agent's label row
    # and its TOTAL row, in the remitter columns of the block. Formulas and
    # the label row's own amount are left alone.
    def amount_cells(grid)
      stop = stop_row(grid)
      block_columns(grid).flat_map do |block_col|
        last = last_remitter_column(grid, block_col)
        in_block = false
        (2...stop).flat_map do |row|
          label = normalize_text(Array(grid[row])[block_col])
          if label == "total"
            in_block = false
            []
          elsif !label.empty?
            in_block = true
            []
          elsif in_block
            ((block_col + 1)..last).select { |col| Array(grid[row])[col].is_a?(Numeric) }.map { |col| [ row, col ] }
          else
            []
          end
        end
      end
    end

    # Cells carrying the "RT<id>" note of a written transfer.
    def marked_cells(title, grid)
      return [] if grid.empty?

      notes = @client.notes(title, "A1:AZ#{grid.length}")
      notes.each_with_index.flat_map do |row, r|
        Array(row).each_with_index.select { |note, _c| note.to_s.match?(MARKER) }.map { |_note, c| [ r, c ] }
      end
    end

    # The bottom accounting area (SP in / MB in / TOTAL AMOUNT …) is manual.
    def stop_row(grid)
      stop = grid.each_with_index.find do |row, index|
        next false if index < 2

        Array(row).any? { |cell| normalize_text(cell).start_with?("total amount") } ||
          %w[sp\ in mb\ in].include?(normalize_text(Array(row)[0]))
      end
      stop ? stop[1] : grid.length
    end

    # Columns that hold an agent label: blank in header row 2, followed by a remitter name.
    def block_columns(grid)
      header = Array(grid[1])
      (0...header.length).select { |col| blank_cell?(header[col]) && !blank_cell?(header[col + 1]) }
    end

    def last_remitter_column(grid, block_col)
      header = Array(grid[1])
      col = block_col + 1
      col += 1 while col + 1 < header.length && !blank_cell?(header[col + 1])
      col
    end
  end
end
