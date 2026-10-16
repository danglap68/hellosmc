module Workbook
  # Applies to the database what a DS MB header says about an agent: a new
  # header text for the same person (rename) or another existing dealer
  # (switch). The sheet is not touched here. Every change is audited.
  module DsHeaderChange
    module_function

    # The header text of the same person changed: remember the new text.
    # Returns true when something changed.
    def rename!(link:, header:, sheet:, source:, transaction: nil)
      text = header.to_s.strip
      return false if text.blank? || text == link.ds_header

      before = link.ds_header
      link.update!(ds_header: text)
      AuditLogger.log!(action: "merchant_dealer.ds_header_synced", auditable: link,
                       metadata: audit_metadata(sheet:, source:, transaction:).merge("from" => before, "to" => text))
      true
    end

    # The header names another dealer: the agent row now belongs to that dealer.
    # The transfer code stays (it belongs to HKD + TID); the thu chi label
    # falls back to the dealer's name. Returns false (nothing changed) when the
    # new dealer cannot take the row, for example it already has this TID.
    def switch!(link:, dealer:, header:, sheet:, source:, transaction: nil)
      previous = link.dealer
      return true if previous == dealer

      MerchantDealer.transaction(requires_new: true) do
        link.update!(dealer: dealer, ds_header: header.to_s.strip)
        AuditLogger.log!(action: "merchant_dealer.agent_switched", auditable: link,
                         metadata: audit_metadata(sheet:, source:, transaction:).merge(
                           "from_dealer_id" => previous.id, "from_dealer" => previous.name,
                           "to_dealer_id" => dealer.id, "to_dealer" => dealer.name, "header" => link.ds_header
                         ))
      end
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      link.reload
      false
    end

    def audit_metadata(sheet:, source:, transaction:)
      { "sheet" => sheet, "source" => source, "transaction_id" => transaction&.id }.compact
    end
  end
end
