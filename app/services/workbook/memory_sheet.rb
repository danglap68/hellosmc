module Workbook
  # In-memory grid used by specs. Same surface as GoogleSheetClient and the
  # same observable behaviour as the real API where it matters:
  #
  # * reads return rows with trailing empty cells dropped, empty rows in the
  #   middle as [], and trailing empty rows omitted
  # * reads render dates as serial numbers; UNFORMATTED_VALUE evaluates
  #   =SUM(...) formulas, FORMULA returns them as text
  # * writes skip nil, clear a cell on "", strip a leading apostrophe and
  #   turn ISO dates into dates (USER_ENTERED)
  # * writing past a sheet's row limit raises, like "exceeds grid limits"
  class MemorySheet
    class GridLimitError < StandardError; end

    EPOCH = Date.new(1899, 12, 30)

    # row_limits: { "MB" => 1000 } turns on the grid limit for those sheets.
    # Positional on purpose: a keyword would make `new("MB" => rows)` fail in Ruby 3.
    def initialize(sheets = {}, row_limits = {})
      @sheets = sheets.transform_values { |rows| rows.map { |row| Array(row).dup } }
      @row_limits = row_limits.dup
    end

    def titles
      @sheets.keys
    end

    def values(sheet, range, value_render_option: "UNFORMATTED_VALUE")
      grid = @sheets.fetch(sheet)
      r1, c1, r2, c2 = parse_range(range, grid)
      limit = @row_limits[sheet]
      raise GridLimitError, "Range #{range} exceeds grid limits. Max rows: #{limit}" if limit && r1 >= limit

      r2 = [ r2, limit - 1 ].min if limit
      rows = (r1..r2).map do |r|
        row = (c1..c2).map { |c| render(grid, grid.dig(r, c), value_render_option) }
        # !row.empty? (not row.any?): [nil].any? is false, so a trailing nil
        # would never be dropped.
        row.pop while !row.empty? && row.last.nil?
        row
      end
      rows.pop while rows.any? && rows.last.empty?
      rows
    end

    def update(sheet, range, rows)
      grid = (@sheets[sheet] ||= [])
      r1, c1, _, _ = parse_range(range, grid)
      limit = @row_limits[sheet]
      if limit && r1 + rows.length > limit
        raise GridLimitError, "Range #{range} exceeds grid limits. Max rows: #{limit}"
      end

      rows.each_with_index do |row, ri|
        grid[r1 + ri] ||= []
        row.each_with_index do |value, ci|
          next if value.nil?

          grid[r1 + ri][c1 + ci] = store(value)
        end
      end
    end

    def batch_update_values(updates)
      updates.each { |update| update(update[:sheet], update[:range], update[:rows]) }
    end

    def duplicate_sheet(source_title:, dest_title:)
      @sheets[dest_title] = @sheets.fetch(source_title).map(&:dup)
      @row_limits[dest_title] = @row_limits[source_title] if @row_limits.key?(source_title)
    end

    def rename_sheet(from:, to:)
      @sheets = @sheets.to_h { |title, rows| [ title == from ? to : title, rows ] }
      @row_limits[to] = @row_limits.delete(from) if @row_limits.key?(from)
    end

    def delete_sheet(title)
      @sheets.delete(title)
      @row_limits.delete(title)
    end

    def ensure_rows(title, min_rows)
      limit = @row_limits[title]
      @row_limits[title] = min_rows + 200 if limit && limit < min_rows
    end

    # Same observable behaviour as GoogleSheetClient#insert_columns: only rows
    # 0...end_row shift right.
    def insert_columns(title, col:, end_row:, min_cols: nil)
      grid = @sheets.fetch(title)
      (0...[ end_row, grid.length ].min).each do |r|
        row = grid[r] ||= []
        row.fill(nil, row.length...col) if row.length < col
        row.insert(col, nil)
      end
    end

    # Raw stored value (formulas as text, dates as Date).
    def cell(sheet, a1)
      @sheets.fetch(sheet).dig(row_index(a1), col_index(a1))
    end

    attr_reader :sheets

    private

    def store(value)
      case value
      when ""
        nil
      when /\A'/
        value.delete_prefix("'")
      when /\A\d{4}-\d{2}-\d{2}\z/
        Date.iso8601(value)
      else
        value
      end
    end

    def render(grid, value, option)
      case value
      when nil, "" then nil
      when Date, Time then (value.to_date - EPOCH).to_i
      when String
        value.start_with?("=") && option != "FORMULA" ? evaluate(grid, value) : value
      else value
      end
    end

    # Only what the sheets use: =SUM(B1:B30) on the same sheet.
    def evaluate(grid, formula)
      match = formula.match(/\A=\s*sum\(\s*([A-Z]+\d+)\s*:\s*([A-Z]+\d+)\s*\)\z/i)
      return 0 unless match

      r1, c1 = row_index(match[1]), col_index(match[1])
      r2, c2 = row_index(match[2]), col_index(match[2])
      (r1..r2).sum do |r|
        (c1..c2).sum { |c| grid.dig(r, c).is_a?(Numeric) ? grid.dig(r, c) : 0 }
      end
    end

    # "A1:C2", "A:L" (whole columns), "B7".
    def parse_range(range, grid)
      start, finish = range.split(":")
      finish ||= start
      [
        row_index(start) || 0, col_index(start),
        row_index(finish) || [ grid.length - 1, 0 ].max, col_index(finish)
      ]
    end

    def col_index(a1)
      letters = a1.to_s[/[A-Z]+/i]
      return 0 unless letters

      letters.upcase.chars.reduce(0) { |n, ch| n * 26 + (ch.ord - 64) } - 1
    end

    def row_index(a1)
      number = a1.to_s[/\d+/]
      number ? number.to_i - 1 : nil
    end
  end
end
