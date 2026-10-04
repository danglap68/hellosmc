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

    def self.call(merchant_name:, merchant_identifier: nil, dealer: nil)
      new(merchant_name: merchant_name, merchant_identifier: merchant_identifier, dealer: dealer).call
    end

    def initialize(merchant_name:, merchant_identifier:, dealer:)
      @merchant_name = merchant_name
      @merchant_identifier = merchant_identifier
      @dealer = dealer
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

      scored = active_merchants.includes(:merchant_aliases).map do |merchant|
        names = [ merchant.name ] + merchant.merchant_aliases.select { |a| a.active? && !a.identifier? }.map(&:alias)
        best = names.map { |name| VietnameseText.similarity(core, VietnameseText.core_name(name)) }.max
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

    # One match resolves. Several matches resolve only if the configured
    # dealer narrows them to exactly one; otherwise the result is ambiguous.
    def pick(merchants, method)
      return nil if merchants.empty?
      return Result.new(merchant: merchants.first, method: method, candidates: merchants, score: 1.0) if merchants.one?

      if @dealer
        same_dealer = merchants.select { |merchant| merchant.dealer_id == @dealer.id }
        if same_dealer.one?
          return Result.new(merchant: same_dealer.first, method: method, candidates: merchants, score: 1.0)
        end
      end

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
