module PaymentQrs
  module Snapshot
    module_function

    def call(transaction)
      raise Error, "Chỉ tạo QR cho bill đã duyệt." unless transaction.approved?

      dealer = Dealer.find_by(id: transaction.dealer_id, active: true)
      raise Error, "Đại lý chưa có đủ thông tin ngân hàng." unless dealer &&
        Banks.name(dealer.bank_bin) && dealer.bank_account_number.present? && dealer.bank_account_name.present?
      raise Error, "Chưa có số tiền đại lý nhận sau phí hợp lệ." unless transaction.dealer_amount_vnd.to_i.between?(1, 10**13 - 1)

      links = MerchantDealer.active.where(merchant_id: transaction.merchant_id, dealer_id: transaction.dealer_id).to_a
      resolved_id = transaction.source_data.dig("dealer_resolution", "merchant_dealer_id")
      link = links.find { |candidate| candidate.id == resolved_id } if resolved_id
      if link.nil? && links.size > 1
        tid = Workbook::TidParser.call(transaction.raw_merchant_name)
        matches = links.select { |candidate| candidate.tid_key == tid }
        link = matches.one? ? matches.first : nil
      end
      link ||= links.first if links.one?
      raise Error, "Chưa xác định duy nhất mã chuyển tiền cho HKD / đại lý / TID của bill." unless link&.transfer_code.present?
      raise Error, "Mã chuyển tiền quá dài cho QR (tối đa 25 ký tự)." if link.transfer_code.bytesize > 25

      {
        "dealer_id" => dealer.id, "dealer_name" => dealer.name,
        "merchant_id" => transaction.merchant_id, "merchant_name" => transaction.merchant&.name,
        "merchant_dealer_id" => link.id, "transfer_code" => link.transfer_code,
        "bank_bin" => dealer.bank_bin, "bank_name" => Banks.name(dealer.bank_bin),
        "account_number" => dealer.bank_account_number, "account_name" => dealer.bank_account_name,
        "dealer_amount_vnd" => transaction.dealer_amount_vnd,
        "bill_amount_vnd" => transaction.transaction_amount_vnd,
        "approved_at" => transaction.approved_at&.iso8601(6),
        "transaction_at" => transaction.transaction_at&.iso8601(6)
      }
    end
  end
end
