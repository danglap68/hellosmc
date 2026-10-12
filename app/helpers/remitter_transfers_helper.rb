module RemitterTransfersHelper
  TRANSFER_STATUS_COLORS = {
    "processing" => "blue", "needs_review" => "yellow", "approved" => "green", "rejected" => "red", "failed" => "red"
  }.freeze

  def remitter_transfer_status_badge(transfer)
    color = TRANSFER_STATUS_COLORS.fetch(transfer.status, "secondary")
    content_tag(:span, t("activerecord.enums.remitter_transfer.status.#{transfer.status}"), class: "badge bg-#{color}-lt")
  end

  # "TK01 · Thiên Kim GV · Chương" for every code of the constant table.
  def remitter_transfer_code_options
    RemitterTransfers::Codes.all.values.map do |entry|
      hkd = Workbook::Seed::HKD.find { |attrs| attrs[:code] == entry.hkd }&.dig(:anchor) || entry.hkd
      [ [ entry.code, hkd, entry.agent ].compact.join(" · "), entry.code ]
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
end
