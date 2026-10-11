module Workbook
  # Cell, text and A1 helpers shared by the Hello SMC sheet writers.
  module SheetText
    CHANNEL_SUFFIX = /(?:\s+(?:mb|sp|qr))+\z/

    private

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

    # OCR/admin text is written with USER_ENTERED so formulas work; a leading
    # = + - @ would be run as a formula, so force it to literal text.
    def text_cell(value)
      text = value.to_s
      text.match?(/\A[=+\-@\t\r]/) ? "'#{text}" : text
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

    def a1(row, col)
      "#{col_letters(col)}#{row + 1}"
    end
  end
end
