module RemitterTransfers
  # Transfer codes ("TK01") typed by a remitter in the Telegram caption of a
  # transfer photo. Each code names one HKD + agent TID, i.e. one
  # merchant_dealers row, and is set on that row (HKD page, "Mã chuyển tiền").
  module Codes
    # Letters then digits: the trailing digits let the matcher tell TK01 from TK010.
    FORMAT = /\A[A-Z]+\d+\z/

    module_function

    # Zero padding in the numeric part is presentation: TK01 == TK1,
    # while TK10 stays distinct. Never remove internal or trailing zeros.
    def canonical(code)
      match = code.to_s.upcase.gsub(/\s+/, "").match(/\A([A-Z]+)(\d+)\z/)
      return unless match

      "#{match[1]}#{match[2].sub(/\A0+(?=\d)/, '')}"
    end

    # Every configured code, active agent row or not: a code of a switched-off
    # agent is still recognised, and reported as such (code_dealer_inactive).
    def codes
      MerchantDealer.where.not(transfer_code: nil).pluck(:transfer_code)
    end

    # { "TK01" => merchant_dealers row } with HKD and agent loaded, for display.
    def all
      MerchantDealer.where.not(transfer_code: nil).includes(:merchant, :dealer).order(:transfer_code)
        .index_by(&:transfer_code)
    end

    # The active agent row a code points to, or nil.
    def merchant_dealer_for(code)
      return nil if code.blank?

      key = canonical(code)
      return unless key

      # Include inactive rows when checking ambiguity: an old code must not
      # silently send money to a different, active agent after normalization.
      matches = MerchantDealer.where.not(transfer_code: nil).select { |row| canonical(row.transfer_code) == key }
      matches.one? && matches.first.active? ? matches.first : nil
    end
  end
end
