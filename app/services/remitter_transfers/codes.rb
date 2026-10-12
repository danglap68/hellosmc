module RemitterTransfers
  # Transfer codes ("TK01") typed by a remitter in the Telegram caption of a
  # transfer photo. Each code names one HKD + agent TID, i.e. one
  # merchant_dealers row, and is set on that row (HKD page, "Mã chuyển tiền").
  module Codes
    # Letters then digits: the trailing digits let the matcher tell TK01 from TK010.
    FORMAT = /\A[A-Z]+\d+\z/

    module_function

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

      MerchantDealer.active.find_by(transfer_code: code.to_s.upcase)
    end
  end
end
