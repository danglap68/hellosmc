module Dealers
  # The dealer is the agent under a resolved HKD. Two hints, never guessed:
  #   * the TID suffix on the OCR merchant name ("… GV-1", "… COFEE 2")
  #   * the agent named in the Telegram group title ("TenDaiLy-HKD1-HKD2")
  #   * the receiving account holder on a bank transfer ("TRAN NGUYEN KHANH SON"
  #     → agent Sơn); only when exactly one agent of the HKD matches the name
  # All point into merchant_dealers (HKD + agent + TID), which is the mapping
  # between TenDaiLy and TID. When several are present they must agree.
  class Resolver
    Result = Data.define(:dealer, :merchant_dealer, :source, :issue) do
      def resolved?
        dealer.present? && issue.nil?
      end
    end

    def self.call(merchant:, merchant_name:, chat: nil, recipient_name: nil)
      new(merchant:, merchant_name:, chat:, recipient_name:).call
    end

    def initialize(merchant:, merchant_name:, chat: nil, recipient_name: nil)
      @merchant = merchant
      @merchant_name = merchant_name
      @chat = chat
      @recipient_name = recipient_name
    end

    def call
      return unresolved(nil) if @merchant.nil?

      result = resolve_by_tid_and_group
      recipient_dealer = dealer_named_by_recipient
      return result unless recipient_dealer

      reconcile_recipient(result, recipient_dealer)
    end

    private

    def resolve_by_tid_and_group
      tid_key = Workbook::TidParser.call(@merchant_name)
      group_dealer = @chat&.group_dealer
      links = MerchantDealer.active.where(merchant: @merchant)

      if group_dealer
        resolve_with_group(links, group_dealer, tid_key)
      else
        return unresolved(nil) if tid_key.blank?

        link = links.find_by(tid_key: tid_key)
        link ? resolved(link, "tid") : unresolved(nil)
      end
    end

    def resolve_with_group(links, group_dealer, tid_key)
      scoped = links.where(dealer: group_dealer)
      if tid_key.present?
        link = scoped.find_by(tid_key: tid_key)
        return resolved(link, "group_tid") if link
        # The TID exists but belongs to another agent than the group's.
        return mismatch if links.exists?(tid_key: tid_key)

        return unresolved(nil)
      end

      candidates = scoped.limit(2).to_a
      candidates.one? ? resolved(candidates.first, "group") : unresolved(nil)
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

    # The recipient never overrides TID/group: it fills the gap when they say
    # nothing, and must agree when they do.
    def reconcile_recipient(result, recipient_dealer)
      if result.dealer
        return result if result.dealer == recipient_dealer

        return Result.new(dealer: nil, merchant_dealer: nil, source: nil, issue: "dealer_recipient_mismatch")
      end
      return result if result.issue == "dealer_group_mismatch"
      return result if Workbook::TidParser.call(@merchant_name).present?

      group_dealer = @chat&.group_dealer
      return result if group_dealer && group_dealer != recipient_dealer

      candidates = MerchantDealer.active.where(merchant: @merchant, dealer: recipient_dealer).limit(2).to_a
      candidates.one? ? resolved(candidates.first, "recipient") : result
    end

    def resolved(link, source)
      dealer = link.dealer
      return Result.new(dealer:, merchant_dealer: link, source:, issue: "dealer_inactive") unless dealer.active?

      Result.new(dealer:, merchant_dealer: link, source:, issue: nil)
    end

    def mismatch
      Result.new(dealer: nil, merchant_dealer: nil, source: nil, issue: "dealer_group_mismatch")
    end

    def unresolved(merchant_dealer)
      Result.new(dealer: nil, merchant_dealer: merchant_dealer, source: nil, issue: "dealer_unmapped")
    end
  end
end
