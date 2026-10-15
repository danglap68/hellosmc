module RemitterTransfers
  # Fills a RemitterTransfer after its photo was OCR'd (or its caption edited)
  # and decides: approved (written to the sheet) or needs_review.
  #
  # Approved needs all of: an amount read with confidence >= the auto-approve
  # threshold (92%), exactly one known code in the caption or a confidently
  # read bank-transfer memo, with no source conflict, pointing
  # to an active agent row, an active remitter, and no likely duplicate.
  # A transfer a person already decided, or already written, is left alone.
  class Builder
    def self.call(remitter_transfer:)
      new(remitter_transfer).call
    end

    def initialize(remitter_transfer)
      @transfer = remitter_transfer
    end

    def call
      approved = false
      RemitterTransfer.transaction do
        @transfer.lock!
        next if @transfer.written? || @transfer.reviewed_by_human? || @transfer.rejected?
        next if ocr_pending?

        before = snapshot
        attributes, reasons = evaluate
        status = decided_status(attributes, reasons)
        @transfer.update!(attributes.except(:status).merge(status: status, review_reasons: reasons))
        @transfer.telegram_message.update!(processing_status: status == "rejected" ? "ignored" : "processed")
        AuditLogger.log!(action: "remitter_transfer.evaluated", auditable: @transfer,
                         before_data: before, after_data: snapshot)
        approved = @transfer.approved?
      end
      enqueue_write if approved
      @transfer
    end

    private

    def decided_status(attributes, reasons)
      return attributes[:status] if attributes[:status].in?(%w[failed rejected])

      reasons.empty? ? "approved" : "needs_review"
    end

    # The photo is still being downloaded or read (e.g. a caption edit arrived first).
    def ocr_pending?
      image = @transfer.telegram_message.bill_images.order(:id).first
      source = image&.duplicate_of || image
      source.present? && source.ocr_status.in?(%w[pending processing])
    end

    def evaluate
      image = @transfer.bill_image || @transfer.telegram_message.bill_images.order(:id).first
      source = image&.duplicate_of || image
      return [ { status: "failed" }, [ "image_missing" ] ] unless source
      return [ { status: "failed", bill_image: image }, [ "ocr_failed" ] ] if source.ocr_failed?
      # A calculator, a sale slip, any photo that is not a bank transfer: skipped, nobody has to look.
      return [ { status: "rejected", bill_image: image }, [ "not_a_transfer" ] ] if not_a_transfer?(source)

      reasons = vision_review_reasons(source)
      amount, confidence, amount_issue = amount_reading(source)
      reasons << amount_issue if amount_issue

      match = CodeResolver.call(caption: @transfer.caption, image: source)
      reasons << match.issue if match.issue
      link = match.code ? Codes.merchant_dealer_for(match.code) : nil
      reasons << "code_dealer_inactive" if match.code && link.nil?

      if @transfer.remitter.nil?
        reasons << "remitter_unknown"
      elsif !@transfer.remitter.active?
        reasons << "remitter_inactive"
      end
      duplicate_check = DuplicateDetector.call(transfer: @transfer, image: image, amount: amount, code: match.code)
      reasons << "possible_duplicate" if duplicate_check.possible_duplicate?

      attributes = {
        bill_image: image,
        amount_vnd: amount,
        amount_confidence: confidence,
        transfer_code: match.code,
        code_source: match.source,
        merchant_dealer: link,
        merchant: link&.merchant,
        metadata: @transfer.metadata.merge("duplicate_check" => duplicate_check.snapshot)
      }
      [ attributes, reasons.uniq ]
    end

    # OCR read the photo and found no bank transfer (and no settlement bill,
    # which AnalyzeBillImageJob hands to the transaction flow). A run that went
    # wrong or has conflicting evidence says nothing conclusive about the
    # photo. Preserve those warnings for a person, even with a valid caption.
    def not_a_transfer?(image)
      return false unless image.ocr_completed? || image.ocr_needs_review?
      return false if vision_review_reasons(image).any?

      image.documents.none? { |doc| doc["document_type"].in?(%w[transfer settlement]) }
    end

    def vision_review_reasons(image)
      BillVision::ImageIntegrity.blocking_reasons(
        image.documents.flat_map { |doc| Array(doc["vision_review_reasons"]) }
      )
    end

    # Transfer documents win over
    # anything else the model saw; two different amounts are not guessed.
    def amount_reading(image)
      documents = image.documents.select { |doc| doc["total_amount_vnd"].present? }
      candidates = documents.select { |doc| doc["document_type"] == "transfer" }.presence || documents
      amounts = candidates.map { |doc| doc["total_amount_vnd"] }.uniq
      return [ nil, nil, "amount_missing" ] if amounts.empty?
      return [ nil, nil, "amount_ambiguous" ] if amounts.size > 1

      document = candidates.first
      confidence = BigDecimal(document.dig("confidence", "total_amount_vnd").to_s.presence || "0")
      confirmed = Array(document["validation_confirmed_fields"]).include?("total_amount_vnd")
      issue = "amount_low_confidence" if !confirmed && confidence < AppConfig.ocr_auto_approve_threshold
      [ amounts.first, confidence.round(4), issue ]
    end

    def enqueue_write
      id = @transfer.id
      ActiveRecord.after_all_transactions_commit { WriteRemitterReportJob.perform_later(id) }
    end

    def snapshot
      @transfer.attributes.slice("status", "transfer_code", "merchant_dealer_id", "amount_vnd", "amount_confidence",
                                 "review_reasons")
    end
  end
end
