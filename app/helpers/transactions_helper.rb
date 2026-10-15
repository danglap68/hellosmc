module TransactionsHelper
  def image_integrity_badge(transaction)
    assessment = transaction.image_integrity_assessment
    status = assessment&.dig("status") || "not_assessed"
    score = assessment&.dig("risk_score")
    valid_score = score.is_a?(Numeric) && score.finite? && score.between?(0, 1)
    text = valid_score ? t("image_integrity.score", percent: (score * 100).round) : t("image_integrity.no_score")
    color = status == "suspicious" ? "yellow" : "secondary"
    hint = [ t("image_integrity.hint"), t("image_integrity.statuses.#{status}", default: status) ].join(" ")
    content_tag(:span, text, class: "badge bg-#{color}-lt text-nowrap", title: hint,
                aria: { label: "#{text}. #{hint}" }, data: { testid: "image-integrity-score" })
  end

  def suggested_rejection_reason(transaction)
    duplicate_ids = Array(transaction.source_data["possible_duplicate_ids"]).compact.uniq
    if duplicate_ids.any?
      return t("transactions.rejection.duplicate", ids: duplicate_ids.map { |id| "##{id}" }.join(", "))
    end

    transaction.review_reason_codes.map { |code| review_reason_label(code) }.join("; ")
  end
end
