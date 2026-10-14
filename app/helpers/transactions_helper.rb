module TransactionsHelper
  def suggested_rejection_reason(transaction)
    duplicate_ids = Array(transaction.source_data["possible_duplicate_ids"]).compact.uniq
    if duplicate_ids.any?
      return t("transactions.rejection.duplicate", ids: duplicate_ids.map { |id| "##{id}" }.join(", "))
    end

    transaction.review_reason_codes.map { |code| review_reason_label(code) }.join("; ")
  end
end
