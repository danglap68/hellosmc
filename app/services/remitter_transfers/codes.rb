module RemitterTransfers
  # Transfer codes ("TK01") typed by a remitter in the Telegram caption of a
  # transfer photo. Each code names one HKD + agent TID, i.e. one
  # merchant_dealers row. The table is a constant (config/remitter_transfer_codes.json),
  # not database data: changing a code is a code change.
  #
  # "hkd" is the HKD code of Workbook::Seed::HKD; production may still hold the
  # older code in match_code ("002 CHERRY COFFE", "099"), so both are tried.
  module Codes
    PATH = Rails.root.join("config/remitter_transfer_codes.json")
    # Letters then digits: the trailing digits let the matcher tell TK01 from TK010.
    FORMAT = /\A[A-Z]+\d+\z/

    Entry = Data.define(:code, :hkd, :tid, :agent)

    class InvalidTable < StandardError; end

    module_function

    def all
      @all ||= load_table
    end

    def codes
      all.keys
    end

    def fetch(code)
      all[code.to_s.upcase]
    end

    # The active merchant_dealers row a code points to, or nil.
    def merchant_dealer_for(code)
      entry = fetch(code)
      return nil unless entry

      merchant = merchant_for(entry.hkd)
      return nil unless merchant

      MerchantDealer.active.find_by(merchant: merchant, tid_key: entry.tid)
    end

    def merchant_for(hkd_code)
      hkd_codes(hkd_code).each do |code|
        merchant = Merchant.find_by(code: code)
        return merchant if merchant
      end
      nil
    end

    # Merchant codes an HKD of the table may carry: the seed's older
    # match_code first, then the table code (upper-cased like Merchant#code).
    def hkd_codes(hkd_code)
      seed = Workbook::Seed::HKD.find { |attrs| attrs[:code] == hkd_code }
      [ seed&.dig(:match_code), hkd_code ].compact.map(&:upcase).uniq
    end

    # Codes that resolve to a merchant_dealers row (admin display). Compares
    # codes in memory: no query per table entry.
    def for_merchant_dealer(merchant_dealer)
      merchant_code = merchant_dealer.merchant.code
      all.values.select do |entry|
        entry.tid == merchant_dealer.tid_key && hkd_codes(entry.hkd).include?(merchant_code)
      end.map(&:code)
    end

    def load_table
      raw = JSON.parse(PATH.read)
      table = raw.to_h do |code, attrs|
        raise InvalidTable, "invalid transfer code #{code.inspect}" unless code.match?(FORMAT)

        [ code, Entry.new(code: code, hkd: attrs.fetch("hkd"), tid: attrs.fetch("tid"), agent: attrs["agent"]) ]
      end
      pairs = table.values.map { |entry| [ entry.hkd, entry.tid ] }
      raise InvalidTable, "two codes point to the same HKD + TID" if pairs.uniq.size != pairs.size

      table.freeze
    end
  end
end
