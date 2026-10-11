module RemitterTransfers
  # Finds the transfer code in a Telegram caption.
  #
  # Diacritics are dropped, letters upper-cased and every run of other
  # characters becomes one space, so the words around the code stay apart:
  # "Zalo TK01 29.274.000" -> "ZALO TK01 29 274 000". A configured code matches
  # with an optional space between its letters and digits ("tk 01", "TK-01")
  # when no digit follows it (TK01 is not found in TK010 or in "TK0129274000"
  # glued to an amount). Anything may precede it ("ZALOTK01", "abcTK01").
  # Only configured codes are looked for.
  class CodeMatcher
    Result = Data.define(:code, :issue) do
      def found? = code.present?
    end

    # strict: the code must be a word of its own ("chuyen TK01", "tk 01"), not
    # glued to other letters ("BICH 01" would otherwise read CH01). Used to
    # route photos of senders who are not known remitters, where a settlement
    # caption must not be mistaken for a transfer.
    def self.call(text, codes: Codes.codes, strict: false)
      new(text, codes, strict).call
    end

    def initialize(text, codes, strict = false)
      @text = VietnameseText.strip_diacritics(text).upcase.gsub(/[^A-Z0-9]+/, " ")
      @codes = codes
      @strict = strict
    end

    def call
      found = @codes.select { |code| @text.match?(pattern(code)) }
      # A code inside a longer matched code ("TK01" in "XTK01") is the same hit.
      found = found.reject { |code| found.any? { |other| other != code && other.include?(code) } }

      return Result.new(code: nil, issue: "code_missing") if found.empty?
      return Result.new(code: nil, issue: "code_ambiguous") if found.size > 1

      Result.new(code: found.first, issue: nil)
    end

    private

    def pattern(code)
      letters, digits = code.match(/\A([A-Z]+)(\d+)\z/).captures
      @strict ? /(?<![A-Z0-9])#{letters} ?#{digits}(?![A-Z0-9])/ : /#{letters} ?#{digits}(?!\d)/
    end
  end
end
