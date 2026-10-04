module Transactions
  # Creates one auditable transaction per settlement found in an analyzed
  # BillImage, then auto-approves it or sends it to manual review.
  #
  # Idempotent: (bill_image, source_index) is unique, and an existing
  # transaction is only rebuilt while it is `processing` (i.e. reprocessing).
  #
  # Reprocessing re-reads the whole image, and the model may return the
  # settlements in another order or a different number of them. Rebuilt rows
  # are therefore matched to the new documents by content, documents that
  # belong to rows already decided are left alone, new documents never
  # auto-approve, and on multi-settlement images every rebuilt row is reviewed.
  class Builder
    MATCH_SCORES = { amount: 2, time: 2, lot: 1, merchant: 1 }.freeze

    def self.call(bill_image:)
      new(bill_image).call
    end

    def initialize(bill_image)
      @bill_image = bill_image
    end

    def call
      return [] if @bill_image.ocr_duplicate? || @bill_image.duplicate_of_id.present?
      return [ build_failed(0) ] + fail_leftovers if @bill_image.ocr_failed?
      return [] unless @bill_image.ocr_completed? || @bill_image.ocr_needs_review?

      dealer_result = Dealers::Resolver.call(bill_image: @bill_image)
      processing_rows = @bill_image.transactions.where(status: "processing").order(:source_index).to_a
      transactions =
        if processing_rows.any?
          rebuild(processing_rows, dealer_result)
        else
          first_build(dealer_result)
        end
      @bill_image.telegram_message&.update!(processing_status: "processed")
      transactions
    end

    private

    # First analysis (or a retry of it): one row per document, keyed by position.
    def first_build(dealer_result)
      @bill_image.documents.filter_map do |document|
        index = document.fetch("index")
        if skippable_child_receipt?(document)
          record_skipped(index)
          next
        end

        build_document(document, index, dealer_result)
      end
    end

    def rebuild(processing_rows, dealer_result)
      decided_rows = @bill_image.transactions.where.not(status: "processing").to_a
      documents = @bill_image.documents.reject { |document| skippable_child_receipt?(document) }
      # A settlement that already has a decided row is not booked twice.
      available = documents.reject { |document| decided_rows.any? { |row| same_settlement?(row, document) } }
      multi_settlement = @bill_image.documents.size > 1 || decided_rows.any? || processing_rows.size > 1

      assignments = {}
      processing_rows.each do |row|
        assignments[row] = best_match(row, available - assignments.values.compact)
      end

      results = processing_rows.map do |row|
        document = assignments[row]
        if document
          build_document(document, row.source_index, dealer_result,
                         extra_reasons: multi_settlement ? [ "reprocessed_multi_settlement" ] : [])
        else
          move_leftover(row, "needs_review", "document_missing_after_reprocess")
        end
      end

      next_index = @bill_image.transactions.maximum(:source_index).to_i + 1
      (available - assignments.values.compact).each_with_index do |document, offset|
        results << build_document(document, next_index + offset, dealer_result,
                                  extra_reasons: [ "document_added_after_reprocess" ])
      end
      results
    end

    def build_document(document, index, dealer_result, extra_reasons: [])
      with_transaction_row(index) do |transaction, creating|
        before = creating ? nil : transaction.audit_snapshot
        evaluation = Evaluator.call(document: document, bill_image: @bill_image, dealer_result: dealer_result)

        transaction.assign_attributes(evaluation.attributes)
        transaction.source_data = evaluation.source_data
        lock_duplicate_scope(transaction)
        transaction.save!

        reasons = evaluation.review_reasons + extra_reasons
        duplicates = DuplicateDetector.call(transaction)
        reasons += [ "possible_duplicate" ] if duplicates.possible_duplicate?
        transaction.source_data = transaction.source_data.merge(
          "review_reasons" => reasons.uniq,
          "possible_duplicate_ids" => duplicates.possible_duplicate_ids
        )

        finish(transaction, reasons.uniq, before: before, creating: creating)
      end
    end

    # Serializes concurrent builds of the same merchant + amount so the
    # duplicate detector always sees the other, committed row.
    def lock_duplicate_scope(transaction)
      return unless transaction.merchant_id && transaction.transaction_amount_vnd

      key = "duplicate:#{transaction.merchant_id}:#{transaction.transaction_amount_vnd}"
      Transaction.connection.execute(
        Transaction.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", key ])
      )
    end

    # Child receipts are only skipped when the model is confident they are not settlements.
    def skippable_child_receipt?(document)
      document["document_type"] == "child_receipt" && !document["requires_review"]
    end

    def same_settlement?(row, document)
      amount = document["total_amount_vnd"]
      at = document["transaction_at"].presence && Time.zone.parse(document["transaction_at"])
      amount.present? && at.present? && row.transaction_amount_vnd == amount && row.transaction_at == at
    end

    # Highest content score wins; without any signal, fall back to position.
    def best_match(row, candidates)
      return nil if candidates.empty?

      previous = row.extraction
      scored = candidates.map { |document| [ document, match_score(row, previous, document) ] }
      best_document, best_score = scored.max_by { |(_document, score)| score }
      return best_document if best_score.positive?

      candidates.find { |document| document["index"] == row.source_index } || candidates.first
    end

    def match_score(row, previous, document)
      score = 0
      amount = document["total_amount_vnd"]
      score += MATCH_SCORES[:amount] if amount && [ row.transaction_amount_vnd, previous["total_amount_vnd"] ].include?(amount)
      at = document["transaction_at"].presence && Time.zone.parse(document["transaction_at"])
      score += MATCH_SCORES[:time] if at && (row.transaction_at == at || previous["transaction_at"] == document["transaction_at"])
      lot = document["lot_number"]
      score += MATCH_SCORES[:lot] if lot && [ row.lot_number, previous["lot_number"] ].include?(lot)
      name = document["merchant_name_normalized"]
      score += MATCH_SCORES[:merchant] if name && previous["merchant_name_normalized"] == name
      score
    end

    def finish(transaction, reasons, before:, creating:)
      auto_approved = reasons.empty?
      if auto_approved
        transaction.transition_to!("approved", approved_at: Time.current, approved_by: nil)
        transaction.reviews.open.find_each { |review| review.update!(status: "superseded") }
      else
        transaction.transition_to!("needs_review")
        open_review(transaction, reasons)
      end

      AuditLogger.log!(
        action: creating ? "transaction.created" : "transaction.rebuilt",
        auditable: transaction,
        before_data: before,
        after_data: transaction.audit_snapshot,
        metadata: { "bill_image_id" => @bill_image.id, "review_reasons" => reasons, "auto_approved" => auto_approved }
      )
      if auto_approved
        AuditLogger.log!(action: "transaction.approved", auditable: transaction,
                         after_data: transaction.audit_snapshot, metadata: { "auto_approved" => true })
      end

      StructuredLog.info("transaction.built", transaction_id: transaction.id, bill_image_id: @bill_image.id,
                                              status: transaction.status, review_reasons: reasons)
      transaction
    end

    def open_review(transaction, reasons)
      transaction.reviews.open.find_each { |review| review.update!(status: "superseded") }
      extraction = transaction.extraction
      transaction.reviews.create!(
        status: "open",
        reason_codes: reasons,
        reason: reasons.join(", "),
        original_values: {
          "merchant_name" => extraction["merchant_name"],
          "terminal_or_merchant_id" => extraction["terminal_or_merchant_id"],
          "total_amount_vnd" => extraction["total_amount_vnd"],
          "lot_number" => extraction["lot_number"],
          "transaction_date" => extraction["transaction_date"],
          "transaction_time" => extraction["transaction_time"],
          "dealer_id" => transaction.dealer_id,
          "merchant_id" => transaction.merchant_id,
          "card_type_id" => transaction.card_type_id,
          "fee_rule_id" => transaction.fee_rule_id
        }
      )
    end

    # OCR failed: keep a visible placeholder so the bill is not lost.
    def build_failed(index)
      with_transaction_row(index) do |transaction, creating|
        before = creating ? nil : transaction.audit_snapshot
        dealer_result = Dealers::Resolver.call(bill_image: @bill_image)
        transaction.assign_attributes(dealer: dealer_result.dealer)
        transaction.source_data = transaction.source_data.merge(
          "review_reasons" => [ "ocr_failed" ],
          "ocr_error" => @bill_image.processing_error,
          "message_text" => @bill_image.message_text
        )
        transaction.save!
        transaction.transition_to!("failed")
        AuditLogger.log!(action: creating ? "transaction.created" : "transaction.rebuilt", auditable: transaction,
                         before_data: before, after_data: transaction.audit_snapshot,
                         metadata: { "bill_image_id" => @bill_image.id, "review_reasons" => [ "ocr_failed" ] })
        transaction
      end
    end

    # Locks or creates the row for (bill_image, index). Yields only when the
    # row is new or being reprocessed; otherwise returns it untouched.
    def with_transaction_row(index)
      Transaction.transaction do
        transaction = Transaction.lock.find_by(bill_image: @bill_image, source_index: index)
        return transaction if transaction && !transaction.processing?

        creating = transaction.nil?
        transaction ||= Transaction.new(
          bill_image: @bill_image,
          source_index: index,
          telegram_message: @bill_image.telegram_message,
          status: "processing"
        )
        yield transaction, creating
      end
    rescue ActiveRecord::RecordNotUnique
      Transaction.find_by!(bill_image: @bill_image, source_index: index)
    end

    def record_skipped(index)
      skipped = (Array(@bill_image.metadata["skipped_child_receipts"]) | [ index ]).sort
      @bill_image.update!(metadata: @bill_image.metadata.merge("skipped_child_receipts" => skipped))
    end

    def fail_leftovers
      @bill_image.transactions.where(status: "processing").where.not(source_index: 0).map do |transaction|
        move_leftover(transaction, "failed", "ocr_failed")
      end
    end

    def move_leftover(transaction, status, reason)
      Transaction.transaction do
        transaction.lock!
        before = transaction.audit_snapshot
        transaction.source_data = transaction.source_data.merge("review_reasons" => [ reason ])
        transaction.transition_to!(status)
        open_review(transaction, [ reason ]) if status == "needs_review"
        AuditLogger.log!(action: "transaction.rebuilt", auditable: transaction, before_data: before,
                         after_data: transaction.audit_snapshot, metadata: { "review_reasons" => [ reason ] })
      end
      transaction
    end
  end
end
