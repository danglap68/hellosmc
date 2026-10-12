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
    # OCR itself went wrong (not "the photo is not a settlement"): the photo
    # must still reach a person even when it reads as unknown.
    OCR_PROBLEM_REASONS =%w[malformed_primary_extraction primary_output_truncated primary_refused
                             validation_budget_exhausted validator_failed].freeze

    def self.call(bill_image:)
      new(bill_image).call
    end

    def initialize(bill_image)
      @bill_image = bill_image
    end

    # A "bill kết" that printed everything it needs needs nothing from the
    # child bills: amount, HKD name, TID/MID, lot, date and time. The agent
    # (the number ending the HKD name) is not required: the POS screen often
    # cuts the name short ("THIÊN KIM..."), and an agent that cannot be told
    # goes to review (dealer_unmapped) instead of waiting on the child bills.
    def self.complete_settlement?(document)
      document["document_type"] == "settlement" &&
        %w[total_amount_vnd merchant_name terminal_or_merchant_id lot_number transaction_date transaction_time]
          .all? { |field| document[field].present? }
    end

    def call
      return [] if @bill_image.ocr_duplicate? || @bill_image.duplicate_of_id.present?
      return [ build_failed(0) ] + fail_leftovers if @bill_image.ocr_failed?
      return [] unless @bill_image.ocr_completed? || @bill_image.ocr_needs_review?

      processing_rows = @bill_image.transactions.where(status: "processing").order(:source_index).to_a
      transactions =
        if processing_rows.any?
          rebuild(processing_rows)
        else
          first_build
        end
      @bill_image.telegram_message&.update!(processing_status: "processed")
      transactions
    end

    private

    # First analysis (or a retry of it): one row per document, keyed by position.
    def first_build
      @bill_image.documents.filter_map do |document|
        index = document.fetch("index")
        if skippable_document?(document)
          record_skipped(index) if document["document_type"] == "child_receipt"
          next
        end

        build_document(document, index)
      end
    end

    def rebuild(processing_rows)
      decided_rows = @bill_image.transactions.where.not(status: "processing").to_a
      documents = @bill_image.documents.reject { |document| skippable_document?(document) }
      # A document another row already stands for is not booked twice. Rows
      # left out of this rerun (still in review, approved, rejected) keep
      # theirs: OCR reads a little differently each run, so an exact match is
      # not required, only a better one than the rows being rebuilt.
      available = documents.reject { |document| claimed_by_other_row?(document, decided_rows, processing_rows) }
      multi_settlement = @bill_image.documents.size > 1 || decided_rows.any? || processing_rows.size > 1

      assignments = {}
      processing_rows.each do |row|
        assignments[row] = best_match(row, available - assignments.values.compact)
      end

      results = processing_rows.map do |row|
        document = assignments[row]
        if document
          build_document(document, row.source_index,
                         extra_reasons: multi_settlement ? [ "reprocessed_multi_settlement" ] : [])
        else
          move_leftover(row, "needs_review", "document_missing_after_reprocess")
        end
      end

      next_index = @bill_image.transactions.maximum(:source_index).to_i + 1
      (available - assignments.values.compact).each_with_index do |document, offset|
        results << build_document(document, next_index + offset,
                                  extra_reasons: [ "document_added_after_reprocess" ])
      end
      results
    end

    def build_document(document, index, extra_reasons: [])
      with_transaction_row(index) do |transaction, creating|
        before = creating ? nil : transaction.audit_snapshot
        document = inherit_album_fields(document)
        forced = transaction.source_data["force_include"] == true
        tag = skip_tag(document) unless forced
        next exclude(transaction, document, tag, before: before, creating: creating) if tag

        evaluation = Evaluator.call(document: document, bill_image: @bill_image)

        transaction.assign_attributes(evaluation.attributes)
        transaction.source_data = evaluation.source_data
        # A person asked for this bill to be booked: it is not excluded again on a rerun.
        transaction.source_data = transaction.source_data.merge("force_include" => true) if forced
        lock_duplicate_scope(transaction)
        transaction.save!

        reasons = evaluation.review_reasons + extra_reasons + album_total_reasons(document)
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

    # In an album the settlement/transfer is the single "tổng kết" transaction,
    # which is never auto-approved: a human confirms it against the child bills.
    # A settlement that printed everything is judged like a single photo: the
    # child bills are dropped, so there is nothing to confirm against them.
    def album_total_reasons(document)
      return [] unless @bill_image.bill_album_id.present?
      return [] unless document["document_type"].in?(%w[settlement transfer])
      return [] if self.class.complete_settlement?(document)

      [ "album_total_review" ]
    end

    # A "tổng kết" (settlement/transfer) often prints only the total, not the
    # merchant/lot/time. Inherit those (and their confidence) from the album's
    # child receipts so the transaction is complete instead of flagged
    # merchant_missing / transaction_time_missing.
    def inherit_album_fields(document)
      return document unless @bill_image.bill_album_id.present?
      return document unless document["document_type"].in?(%w[settlement transfer])
      return document if self.class.complete_settlement?(document)

      children = album_child_receipts
      return document if children.empty?

      merged = document.dup
      confidence = (merged["confidence"] || {}).dup
      inherit_field(merged, confidence, children, "merchant_name", best: true)
      inherit_field(merged, confidence, children, "terminal_or_merchant_id", best: true)
      inherit_field(merged, confidence, children, "lot_number")
      inherit_field(merged, confidence, children, "transaction_time", latest: true)

      if merged["transaction_date"].present? && merged["transaction_time"].present? && merged["transaction_at"].blank?
        date = Date.parse(merged["transaction_date"])
        hour, minute, second = merged["transaction_time"].split(":").map(&:to_i)
        merged["transaction_at"] = Time.zone.local(date.year, date.month, date.day, hour, minute, second).iso8601
      end
      merged["confidence"] = confidence
      refresh_critical_fields(merged, confidence)
      merged
    end

    # The stored critical_confidence / low_confidence_fields were computed from
    # the un-inherited document; recompute them so the summary matches the
    # inherited per-field confidence.
    def refresh_critical_fields(document, confidence)
      type = document["document_type"]
      critical_fields = BillVision::Normalizer::CRITICAL_FIELDS_BY_TYPE.fetch(type, %w[document_type])
      values = critical_fields.to_h { |field| [ field, critical_confidence_value(confidence, field) ] }

      document["critical_confidence"] = values.values.min
      document["low_confidence_fields"] = critical_fields.select do |field|
        BigDecimal(values[field].to_s) < AppConfig.ocr_auto_approve_threshold
      end
      document["requires_review"] = type == "unknown" || document["low_confidence_fields"].any?
    end

    def critical_confidence_value(confidence, field)
      if field == "merchant_name"
        [ confidence["merchant_name"], confidence["terminal_or_merchant_id"] ].compact.max.to_f
      else
        confidence[field].to_f
      end
    end

    # The album's child receipts are loaded once per build and reused for every
    # settlement document, so a multi-settlement image does not re-query the
    # album for each one.
    def album_child_receipts
      @album_child_receipts ||= @bill_image.bill_album.bill_images.analyzable.flat_map(&:documents)
                                   .select { |doc| doc["document_type"] == "child_receipt" }
    end

    def inherit_field(merged, confidence, children, field, latest: false, best: false)
      return if merged[field].present?

      source = if latest
                 children.select { |doc| doc[field].present? }.max_by { |doc| doc[field].to_s }
               elsif best
                 children.select { |doc| doc[field].present? }.max_by do |doc|
                   [ doc[field].to_s.include?("...") ? 0 : 1, doc.dig("confidence", field).to_f ]
                 end
               else
                 children.find { |doc| doc[field].present? }
               end
      return unless source

      merged[field] = source[field]
      confidence[field] = source.dig("confidence", field)
    end

    # Child receipts (bill con) and unreadable documents are evidence, never
    # accounting rows:
    # * inside an album only a "tổng kết" (settlement/transfer) with a readable
    #   amount is built; a nil-amount total (e.g. a confirm popup) is skipped;
    # * outside an album (single image) only settlements are built.
    def skippable_document?(document)
      type = document["document_type"]
      # A single photo only becomes a row when it is a settlement: transfers go
      # to RemitterTransfer, unknown photos and child receipts are skipped
      # instead of cluttering review. An OCR problem (failed run, malformed,
      # truncated or refused output, exhausted budget, failed validator) still
      # reaches a person. Albums keep their handling below.
      # A photo uploaded by hand in the admin was chosen by a person: it is
      # always built so they see the result.
      if @bill_image.telegram? && @bill_image.bill_album_id.blank? && type != "settlement"
        return (Array(document["vision_review_reasons"]) & OCR_PROBLEM_REASONS).empty?
      end

      if @bill_image.bill_album_id.present?
        return true if type.in?(%w[child_receipt unknown])
        return true if type.in?(%w[settlement transfer]) && document["total_amount_vnd"].nil?

        return false
      end

      type == "child_receipt" && !document["requires_review"]
    end

    def same_settlement?(row, document)
      amount = document["total_amount_vnd"]
      at = document["transaction_at"].presence && Time.zone.parse(document["transaction_at"])
      amount.present? && at.present? && row.transaction_amount_vnd == amount && row.transaction_at == at
    end

    def claimed_by_other_row?(document, other_rows, processing_rows)
      return false if other_rows.empty?
      return true if other_rows.any? { |row| same_settlement?(row, document) }

      other = other_rows.map { |row| match_score(row, row.extraction, document) }.max
      return false unless other.positive?

      other >= processing_rows.map { |row| match_score(row, row.extraction, document) }.max.to_i
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
      enqueue_workbook(transaction)
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

    def enqueue_workbook(transaction)
      return unless transaction.finalized?
      return if transaction.transaction_amount_vnd.blank? || transaction.transaction_at.blank?

      # Rows are built inside a DB transaction: enqueue only once it commits, or
      # the worker could read the row still `processing` and skip it for good.
      id = transaction.id
      ActiveRecord.after_all_transactions_commit { WriteHelloSmcWorkbookJob.perform_later(id) }
    end

    # Sales that use another fee calculation (SmartPOS terminals, an HKD with
    # "Bỏ qua bill" on) are kept as an excluded row with a tag instead of being
    # booked: a person can still find them and book them later
    # (Transactions::Includer). A photo uploaded by hand is always built: a
    # person chose it.
    def skip_tag(document)
      return unless @bill_image.telegram?
      return "smart_pos" if document["shows_smart_pos"] == true

      "skip_merchant" if skipped_merchant?(document)
    end

    def skipped_merchant?(document)
      result = Merchants::Resolver.for_document(document)
      return false unless result.merchant&.skip_bills?

      result.exact? || (result.fuzzy? && result.score.to_f >= AppConfig.merchant_auto_accept_score)
    end

    # What the bill says, nothing calculated: no dealer, card type, fee, review,
    # duplicate check, sheet or Excel row.
    def exclude(transaction, document, tag, before:, creating:)
      merchant = excluded_merchant(document)
      transaction.assign_attributes(
        merchant: merchant,
        lot_number: document["lot_number"],
        transaction_at: document["transaction_at"].presence && Time.zone.parse(document["transaction_at"]),
        transaction_amount_vnd: document["total_amount_vnd"],
        confidence_score: document["critical_confidence"],
        tags: [ tag ],
        source_data: {
          "extraction" => document, "message_text" => @bill_image.message_text,
          "ocr_provider" => @bill_image.ocr_provider, "ocr_model" => @bill_image.ocr_model,
          "review_reasons" => [], "excluded_reason" => tag
        }
      )
      transaction.save!
      transaction.transition_to!("excluded")
      AuditLogger.log!(action: creating ? "transaction.created" : "transaction.rebuilt", auditable: transaction,
                       before_data: before, after_data: transaction.audit_snapshot,
                       metadata: { "bill_image_id" => @bill_image.id, "excluded_reason" => tag })
      StructuredLog.info("transaction.excluded", transaction_id: transaction.id, bill_image_id: @bill_image.id, tag: tag)
      transaction
    end

    def excluded_merchant(document)
      result = Merchants::Resolver.for_document(document)
      result.merchant if result.exact? || (result.fuzzy? && result.score.to_f >= AppConfig.merchant_auto_accept_score)
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
