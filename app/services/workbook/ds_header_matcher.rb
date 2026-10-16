module Workbook
  # Finds the DS MB column of an agent by its TID when the header text no
  # longer matches merchant_dealers.ds_header, and says what changed in the
  # person's name.
  #
  # Lookup only: it reads the grid and the dealers and never writes. The writer
  # and the header sync decide what to do with the result.
  #
  # Column: the block of the HKD runs from the anchor cell to the first blank
  # header cell. Headers that already belong to another agent of the same HKD
  # are skipped; the column must be the only one left with the agent's TID.
  #
  # Kind of change, first rule that holds:
  #   same      the person is the agent's current dealer
  #   switch    the name is exactly the name of one other active dealer
  #   rename    one name is a whole-word part of the other ("Nghĩa" / "Nghĩa Nghiệp")
  #   unmatched anything else: new name, several dealers, an inactive dealer, no name
  class DsHeaderMatcher
    include SheetText

    Result = Data.define(:col, :header, :kind, :dealer)
    # change is nil when the header text still matches ds_header.
    Location = Data.define(:header_row, :anchor_col, :col, :change)

    MIN_NAME_LENGTH = 2
    NAME_WINDOW = 6

    def self.call(grid:, header_row:, anchor_col:, link:, last_col:)
      new(grid:, header_row:, anchor_col:, link:, last_col:).call
    end

    # The agent's column in a DS MB grid: by the header text first, then by TID.
    # nil when the HKD's anchor cell is not in the grid; col is nil when neither finds a column.
    def self.locate(grid:, link:, last_col:)
      new(grid:, header_row: nil, anchor_col: nil, link:, last_col:).locate
    end

    def initialize(grid:, header_row:, anchor_col:, link:, last_col:)
      @grid = grid
      @header_row = header_row
      @anchor_col = anchor_col
      @link = link
      @last_col = last_col
    end

    def locate
      @header_row, @anchor_col = find_anchor
      return nil unless @header_row

      col = named_column
      return Location.new(header_row: @header_row, anchor_col: @anchor_col, col:, change: nil) if col

      change = call
      Location.new(header_row: @header_row, anchor_col: @anchor_col, col: change&.col, change:)
    end

    # nil when there is not exactly one column carrying the agent's TID.
    def call
      col = tid_column
      return nil unless col

      header = @grid.dig(@header_row, col).to_s.strip
      kind, dealer = classify(header)
      Result.new(col:, header:, kind:, dealer:)
    end

    private

    def find_anchor
      @grid.each_with_index do |row, r|
        Array(row).each_with_index do |value, c|
          return [ r, c ] if same_text?(value, @link.ds_sheet_anchor)
        end
      end
      [ nil, nil ]
    end

    def named_column
      (@anchor_col..[ @anchor_col + NAME_WINDOW, @last_col ].min).find do |col|
        same_text?(@grid.dig(@header_row, col), @link.ds_header)
      end
    end

    def tid_column
      taken = sibling_headers
      matches = block_columns.select do |col|
        header = @grid.dig(@header_row, col)
        !taken.include?(normalize_text(header)) && TidParser.call(header) == @link.tid_key
      end
      matches.one? ? matches.first : nil
    end

    def block_columns
      columns = []
      col = @anchor_col + 1
      while col <= @last_col && !blank_cell?(@grid.dig(@header_row, col))
        columns << col
        col += 1
      end
      columns
    end

    def sibling_headers
      MerchantDealer.active.where(merchant_id: @link.merchant_id).where.not(id: @link.id)
        .pluck(:ds_header).map { |header| normalize_text(header) }
    end

    def classify(header)
      words = person_words(header)
      return [ :unmatched, nil ] if words.join.length < MIN_NAME_LENGTH

      current = words_of(@link.dealer.name)
      return [ :same, @link.dealer ] if words == current

      same_name = Dealer.where.not(id: @link.dealer_id).select { |dealer| words_of(dealer.name) == words }
      return [ :unmatched, nil ] if same_name.size > 1
      return same_name.first.active? ? [ :switch, same_name.first ] : [ :unmatched, nil ] if same_name.one?
      return [ :rename, @link.dealer ] if whole_words_of?(current, words) || whole_words_of?(words, current)

      [ :unmatched, nil ]
    end

    # "Nghĩa Nghiệp (tid1)" => ["nghia", "nghiep"]; the TID marker and a trailing
    # channel (MB, SP, QR) are not part of the name.
    def person_words(header)
      VietnameseText.normalize(header).gsub(/\b(?:tid|terminal)\s*\d+\b/, " ").squish.sub(CHANNEL_SUFFIX, "").split
    end

    def words_of(name)
      VietnameseText.normalize(name).split
    end

    def whole_words_of?(outer, inner)
      inner.any? && outer.each_cons(inner.length).any?(inner)
    end
  end
end
