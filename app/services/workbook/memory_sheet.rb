module Workbook
  # In-memory grid used by specs. Same surface as GoogleSheetClient.
  class MemorySheet
    def initialize(sheets = {})
      @sheets = sheets.transform_values { |rows| rows.map { |row| Array(row).dup } }
    end

    def titles
      @sheets.keys
    end

    def values(sheet, range)
      grid = @sheets.fetch(sheet)
      r1, c1, r2, c2 = parse_range(range, grid)
      (r1..r2).map { |r| (c1..c2).map { |c| grid.dig(r, c) } }
    end

    def update(sheet, range, rows)
      grid = (@sheets[sheet] ||= [])
      r1, c1, _, _ = parse_range(range, grid)
      rows.each_with_index do |row, ri|
        grid[r1 + ri] ||= []
        row.each_with_index { |value, ci| grid[r1 + ri][c1 + ci] = value }
      end
    end

    def batch_update_values(updates)
      updates.each { |update| update(update[:sheet], update[:range], update[:rows]) }
    end

    def duplicate_sheet(source_title:, dest_title:)
      @sheets[dest_title] = @sheets.fetch(source_title).map(&:dup)
    end

    def cell(sheet, a1)
      values(sheet, "#{a1}:#{a1}").dig(0, 0)
    end

    attr_reader :sheets

    private

    def parse_range(range, grid)
      start, finish = range.split(":")
      finish ||= start
      [ row_index(start), col_index(start), row_index(finish) || [ grid.length - 1, 0 ].max, col_index(finish) || 0 ]
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
