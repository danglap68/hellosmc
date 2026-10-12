module Merchants
  # Maps OCR output to a configured merchant (HKD). Never creates merchants.
  #
  # Order: exact identifier alias -> exact name alias -> normalized merchant
  # name -> fuzzy suggestion. Only the first three are trusted; a fuzzy match
  # is returned as a suggestion that must be confirmed in manual review.
  class Resolver
    Result = Data.define(:merchant, :method, :candidates, :score) do
      # Trusted resolutions that may be auto-approved.
      def exact?
        merchant.present? && method.in?(%i[identifier alias name])
      end

      def fuzzy?
        method == :fuzzy
      end

      def ambiguous?
        method == :ambiguous
      end
    end

    FUZZY_MARGIN = 0.05

    def self.call(merchant_name:, merchant_identifier: nil)
      new(merchant_name:, merchant_identifier:).call
    end

    # Dash/tid suffix stripped first; if that is not an exact hit, also try the
    # name without a bare trailing number ("CHERRY COFFE 2" → "CHERRY COFFE").
    # Prefer the strongest match across attempts: exact → fuzzy → ambiguous →
    # the first attempt (none). This keeps a fuzzy hit from the stripped name
    # ("GẮT TẠM ĐÂY COFFEE 2" → "Gat Tan Day Coffe") instead of discarding it.
    def self.for_document(document)
      name = document["merchant_name"]
      names = [ Workbook::TidParser.strip(name), Workbook::TidParser.strip_bare_number(name) ].uniq
      results = names.map do |candidate|
        call(merchant_name: candidate, merchant_identifier: document["terminal_or_merchant_id"])
      end
      results.find(&:exact?) || results.find(&:fuzzy?) || results.find(&:ambiguous?) || results.first
    end

    def initialize(merchant_name:, merchant_identifier:)
      @merchant_name = merchant_name
      @merchant_identifier = merchant_identifier
    end

    def call
      by_identifier || by_alias || by_name || by_fuzzy || none
    end

    private

    def by_identifier
      identifier = VietnameseText.normalize_identifier(@merchant_identifier)
      return nil if identifier.blank?

      merchants = active_merchants.joins(:merchant_aliases)
        .merge(MerchantAlias.active.identifiers)
        .where(merchant_aliases: { normalized_alias: identifier })
        .distinct.to_a
      pick(merchants, :identifier)
    end

    def by_alias
      return nil if normalized_name.blank?

      merchants = active_merchants.joins(:merchant_aliases)
        .merge(MerchantAlias.active.names)
        .where(merchant_aliases: { normalized_alias: normalized_name })
        .distinct.to_a
      pick(merchants, :alias)
    end

    def by_name
      return nil if normalized_name.blank?

      core = VietnameseText.core_name(@merchant_name)
      merchants = active_merchants.includes(:merchant_aliases).select do |merchant|
        merchant.normalized_name == normalized_name ||
          (core.present? && merchant.core_name == core) ||
          merchant.merchant_aliases.any? { |a| a.active? && !a.identifier? && VietnameseText.core_name(a.alias) == core }
      end
      pick(merchants, :name)
    end

    def by_fuzzy
      core = VietnameseText.core_name(@merchant_name)
      return nil if core.length < 4

      merchants = active_merchants.includes(:merchant_aliases).to_a
      names_of = ->(merchant) { [ merchant.name ] + merchant.merchant_aliases.select { |a| a.active? && !a.identifier? }.map(&:alias) }
      words_of = merchants.to_h { |merchant| [ merchant, names_of.call(merchant).flat_map { |name| significant_words(VietnameseText.core_name(name), minimum: 3) }.uniq ] }
      every_word = words_of.values.flatten.uniq

      scored = merchants.map do |merchant|
        # Words that belong to another HKD: finding one in the OCR name counts against this one.
        foreign = every_word - words_of.fetch(merchant)
        best = names_of.call(merchant).map do |name|
          other = VietnameseText.core_name(name)
          [ VietnameseText.similarity(core, other), compact_similarity(core, other), token_similarity(core, other, foreign) ].max
        end.max
        [ merchant, best ]
      end
      scored.sort_by! { |(_merchant, score)| -score }
      best_merchant, best_score = scored.first
      return nil if best_merchant.nil? || best_score < AppConfig.merchant_fuzzy_threshold

      runner_up = scored.second&.last.to_f
      candidates = scored.first(3).select { |(_m, score)| score >= AppConfig.merchant_fuzzy_threshold - 0.1 }.map(&:first)
      if best_score - runner_up < FUZZY_MARGIN
        return Result.new(merchant: nil, method: :ambiguous, candidates: candidates, score: best_score.round(4))
      end

      Result.new(merchant: best_merchant, method: :fuzzy, candidates: candidates, score: best_score.round(4))
    end

    def none
      Result.new(merchant: nil, method: :none, candidates: [], score: nil)
    end

    # Words OCR and people write for coffee: "COFFEE", "COFFE", "CAFE", "CF"...
    COFFEE_WORDS = %w[coffee coffe cofee cofe caffe caphe cf].freeze

    # The same name with the spaces taken out ("GATTANDAY COFFEE", "THIENKIM GV"),
    # for OCR that ran words together or split them. Short names are left out.
    def compact_similarity(ocr, configured)
      left = ocr.delete(" ").delete("0-9")
      right = configured.delete(" ").delete("0-9")
      return 0.0 if left.length < 8 || right.length < 8

      [ VietnameseText.similarity(left, right), 0.99 ].min
    end

    # How well the distinctive words of two names line up, for names a whole-string
    # comparison misses because OCR garbled the tail ("THIEN KIM GUI" for
    # "THIEN KIM GV") or added words (an address). Each word of the configured name
    # has to be found in the OCR name, allowing one misread letter (two in a long
    # word); words of one or two letters and numbers (the agent's TID) are
    # optional, and the coffee words count as one. Extra words on the OCR side
    # cost little when nobody else uses them (an address) and the full weight when
    # they belong to another HKD ("AS CAFE MILO" is not "AS CAFE"). A name made of
    # fewer than six letters of distinctive words is never matched this way.
    # Always a suggestion: it needs a person to confirm.
    def token_similarity(ocr, configured, foreign)
      ocr_words = significant_words(ocr, minimum: 1)
      words = significant_words(configured, minimum: 3)
      return 0.0 if words.sum(&:length) < 6 || ocr_words.empty?

      remaining = ocr_words.dup
      pairs = words.filter_map do |word|
        found = remaining.index { |candidate| same_word?(word, candidate) }
        next unless found

        candidate = remaining.delete_at(found)
        [ word, candidate, [ word.length, candidate.length ].max * VietnameseText.similarity(word, candidate) ]
      end
      return 0.0 if pairs.sum { |word, _candidate, _letters| word.length } < 6

      # A misread letter counts against the score on both sides: the score is as
      # sure as the letters that agree.
      weight = pairs.sum { |_word, _candidate, letters| letters }
      recall = weight / words.sum(&:length)
      extra = remaining.sum { |word| foreign.any? { |other| same_word?(word, other) } ? word.length : word.length * 0.25 }
      precision = weight / (pairs.sum { |_word, candidate, _letters| candidate.length } + extra)
      # Never a perfect score: a perfect one is an exact name, which this is not.
      [ (2 * precision * recall) / (precision + recall), 0.99 ].min
    end

    def significant_words(text, minimum:)
      text.to_s.split.map { |word| COFFEE_WORDS.include?(word) ? "cafe" : word }
          .reject { |word| word.match?(/\A\d+\z/) || word.length < minimum }
    end

    def same_word?(left, right)
      return true if left == right

      allowed = [ left.length, right.length ].min >= 7 ? 2 : 1
      [ left.length, right.length ].min >= 3 && VietnameseText.levenshtein(left, right) <= allowed
    end

    # One match resolves; several matches are ambiguous (no dealer to narrow).
    def pick(merchants, method)
      return nil if merchants.empty?
      return Result.new(merchant: merchants.first, method: method, candidates: merchants, score: 1.0) if merchants.one?

      Result.new(merchant: nil, method: :ambiguous, candidates: merchants, score: nil)
    end

    def normalized_name
      @normalized_name ||= VietnameseText.normalize(@merchant_name)
    end

    def active_merchants
      Merchant.active
    end
  end
end
