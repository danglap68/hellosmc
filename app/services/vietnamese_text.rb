# Text normalization used for merchant matching and Telegram tag parsing.
# Vietnamese diacritics are removed so that "HỘ KINH DOANH" == "ho kinh doanh".
module VietnameseText
  module_function

  # Legal-form prefixes that do not help identify a business.
  BUSINESS_PREFIXES = [
    "ho kinh doanh ca the", "ho kinh doanh", "hkd",
    "cong ty trach nhiem huu han", "cong ty tnhh mtv", "cong ty tnhh", "cty tnhh",
    "cong ty co phan", "cong ty cp", "cty cp", "cong ty", "cty",
    "doanh nghiep tu nhan", "dntn", "cua hang", "ch"
  ].freeze

  def strip_diacritics(text)
    text.to_s.tr("đĐ", "dD").unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
  end

  # "001_ HỘ KINH DOANH  Thiên-Kim" => "001 ho kinh doanh thien kim"
  def normalize(text)
    strip_diacritics(text).downcase.gsub(/[^a-z0-9]+/, " ").squish
  end

  # Drops a leading numeric code and the legal-form prefix:
  # "001_ HỘ KINH DOANH THIÊN KIM GV" => "thien kim gv"
  def core_name(text)
    value = normalize(text).sub(/\A\d+\s+(?=[a-z])/, "")
    loop do
      prefix = BUSINESS_PREFIXES.find { |candidate| value.start_with?("#{candidate} ") }
      break unless prefix

      value = value.delete_prefix("#{prefix} ")
    end
    value.squish
  end

  # Identifiers such as MID/TID values: "0001-2345 ab" => "00012345AB"
  def normalize_identifier(text)
    strip_diacritics(text).upcase.gsub(/[^A-Z0-9]/, "")
  end

  # Normalized Levenshtein similarity in 0..1.
  def similarity(left, right)
    left = left.to_s
    right = right.to_s
    return 1.0 if left == right
    return 0.0 if left.empty? || right.empty?

    1.0 - (levenshtein(left, right).to_f / [ left.length, right.length ].max)
  end

  def levenshtein(left, right)
    previous = (0..right.length).to_a
    left.each_char.with_index(1) do |left_char, i|
      current = [ i ]
      right.each_char.with_index(1) do |right_char, j|
        cost = left_char == right_char ? 0 : 1
        current << [ current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost ].min
      end
      previous = current
    end
    previous.last
  end
end
