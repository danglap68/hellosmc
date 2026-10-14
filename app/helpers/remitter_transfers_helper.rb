module RemitterTransfersHelper
  TRANSFER_STATUS_COLORS = {
    "processing" => "blue", "needs_review" => "yellow", "approved" => "green", "rejected" => "red", "failed" => "red"
  }.freeze

  def remitter_transfer_status_badge(transfer)
    color = TRANSFER_STATUS_COLORS.fetch(transfer.status, "secondary")
    content_tag(:span, t("activerecord.enums.remitter_transfer.status.#{transfer.status}"), class: "badge bg-#{color}-lt")
  end

  # "TK01 · Thiên Kim GV · Chương" for every configured code.
  def remitter_transfer_code_options
    RemitterTransfers::Codes.all.map do |code, link|
      [ [ code, link.ds_sheet_anchor.presence || link.merchant.name, link.dealer.name ].join(" · "), code ]
    end
  end

  # Date and time printed on the bank slip; "—" when OCR read none.
  def remitter_slip_datetime(transfer)
    slip_at = transfer.slip_at
    return content_tag(:span, "—", class: "text-secondary") unless slip_at

    slip_at.is_a?(Date) ? l(slip_at) : format_datetime(slip_at)
  end

  def remitter_transfer_reason(code)
    t("remitter_transfers.reasons.#{code}", default: t("review_reasons.#{code}", default: code))
  end

  def remitter_transfer_memo(transfer)
    transfer.display_image&.documents.to_a.filter_map do |document|
      document["transfer_memo"].presence if document["document_type"] == "transfer"
    end.uniq.join("; ").presence
  end
end
