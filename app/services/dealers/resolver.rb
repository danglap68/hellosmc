module Dealers
  # The dealer is the agent under a resolved HKD, read from the bill only
  # (the Telegram group and its name play no part). Two hints, never guessed:
  #   * the TID suffix on the OCR merchant name ("… GV-1", "… COFEE 2")
  #   * the receiving account holder on a bank transfer ("TRAN NGUYEN KHANH SON"
  #     → agent Sơn); only when exactly one agent of the HKD matches the name
  # Both point into merchant_dealers (HKD + agent + TID). When both are
  # present they must agree.
  class Resolver
    Result = Data.define(:dealer, :merchant_dealer, :source, :issue) do
      def resolved?
        dealer.present? && issue.nil?
      end
    end

    def self.call(merchant:, merchant_name:, recipient_name: nil)
      new(merchant:, merchant_name:, recipient_name:).call
    end

    def initialize(merchant:, merchant_name:, recipient_name: nil)
      @merchant = merchant
      @merchant_name = merchant_name
      @recipient_name = recipient_name
    end

    def call
      return unresolved(nil) if @merchant.nil?

      result = resolve_by_tid
      recipient_dealer = dealer_named_by_recipient
      return result unless recipient_dealer

      reconcile_recipient(result, recipient_dealer)
    end

    private

    def resolve_by_tid
      tid_key = Workbook::TidParser.call(@merchant_name)
      return unresolved(nil) if tid_key.blank?

      link = MerchantDealer.active.find_by(merchant: @merchant, tid_key: tid_key)
      link ? resolved(link, "tid") : unresolved(nil)
    end

    # Agents of this HKD whose name appears, as whole consecutive words, in the
    # recipient's account name. Zero or several matches give no hint.
    def dealer_named_by_recipient
      recipient = words_of(@recipient_name)
      return nil if recipient.empty?

      dealers = MerchantDealer.active.where(merchant: @merchant).includes(:dealer).map(&:dealer).uniq
      matches = dealers.select do |dealer|
        words = words_of(dealer.name)
        words.any? && recipient.each_cons(words.length).any?(words)
      end
      matches.one? ? matches.first : nil
    end

    def words_of(text)
      VietnameseText.normalize(text.to_s).split
    end

    # The recipient never overrides the TID: it fills the gap when the bill
    # has no TID, and must agree when it has one.
    def reconcile_recipient(result, recipient_dealer)
      if result.dealer
        return result if result.dealer == recipient_dealer

        return Result.new(dealer: nil, merchant_dealer: nil, source: nil, issue: "dealer_recipient_mismatch")
      end
      return result if Workbook::TidParser.call(@merchant_name).present?

      candidates = MerchantDealer.active.where(merchant: @merchant, dealer: recipient_dealer).limit(2).to_a
      candidates.one? ? resolved(candidates.first, "recipient") : result
    end

    def resolved(link, source)
      dealer = link.dealer
      return Result.new(dealer:, merchant_dealer: link, source:, issue: "dealer_inactive") unless dealer.active?

      Result.new(dealer:, merchant_dealer: link, source:, issue: nil)
    end

    def unresolved(merchant_dealer)
      Result.new(dealer: nil, merchant_dealer: merchant_dealer, source: nil, issue: "dealer_unmapped")
    end
  end
end
