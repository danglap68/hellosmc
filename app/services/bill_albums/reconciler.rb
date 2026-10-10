module BillAlbums
  # After every image of an album is OCR'd: builds one transaction per child
  # bill (child_receipt), then reconciles sum(child bills) against the "tổng
  # kết" total. The total comes from a settlement (POS batch closing) or a
  # transfer (bank transfer) — either one is accepted dynamically.
  # Decision + persistence only; never changes transaction amounts.
  class Reconciler
    TOTAL_TYPES = %w[settlement transfer].freeze

    def self.call(album)
      new(album).call
    end

    def initialize(album)
      @album = album
    end

    def call
      scan_documents
      build_child_transactions
      apply_decision
      persist
      @album
    end

    private

    def scan_documents
      @child_total = 0
      @child_count = 0
      @total_count = 0
      @total_amounts = []
      @total_image = nil
      @amount_missing = false

      @album.bill_images.analyzable.each do |image|
        image.documents.each do |doc|
          case doc["document_type"]
          when "child_receipt"
            @child_count += 1
            amount = doc["total_amount_vnd"]
            @amount_missing = true if amount.nil?
            @child_total += amount.to_i
          when *TOTAL_TYPES
            @total_count += 1
            @total_amounts << doc["total_amount_vnd"]
            @total_image ||= image
          end
        end
      end
    end

    def total_duplicate?
      return false unless @total_count.zero?

      @album.bill_images.where.not(duplicate_of_id: nil).any? do |image|
        image.duplicate_of&.documents&.any? { |doc| doc["document_type"].in?(TOTAL_TYPES) }
      end
    end

    def build_child_transactions
      return unless @total_count >= 1 && @child_count >= 1

      @album.bill_images.analyzable.each do |image|
        Transactions::Builder.call(bill_image: image)
      end
    end

    def apply_decision
      if @total_count.zero?
        @status = "skipped"
        @reconciliation_status = total_duplicate? ? "transfer_duplicate" : "no_transfer"
        @flag_reason = nil
        @skip_reason = total_duplicate? ? "transfer_duplicate" : nil
      elsif @album.any_ocr_failed?
        @status = "needs_review"
        @reconciliation_status = "incomplete"
        @flag_reason = "album_ocr_failed"
      elsif @total_count > 1
        @status = "needs_review"
        @reconciliation_status = "multiple_transfers"
        @flag_reason = "album_multiple_transfers"
      elsif @child_count.zero?
        @status = "needs_review"
        @reconciliation_status = "missing_bills"
        @flag_reason = nil
      elsif @amount_missing
        @status = "needs_review"
        @reconciliation_status = "incomplete"
        @flag_reason = "album_amount_unreadable"
      elsif @child_total == @total_amounts.first
        @status = "reconciled"
        @reconciliation_status = "matched"
        @flag_reason = nil
      else
        @status = "needs_review"
        @reconciliation_status = "mismatched"
        @flag_reason = "album_total_mismatch"
      end
    end

    def persist
      Transactions::Flagger.call(transactions: @album.transactions, reason: @flag_reason) if @flag_reason

      total_amount = @total_count == 1 ? @total_amounts.first : nil
      total_image = @total_count == 1 ? @total_image : nil
      metadata = @album.metadata
      metadata = metadata.merge("total_amounts" => @total_amounts) if @total_count > 1
      metadata = metadata.merge("skip_reason" => @skip_reason) if @skip_reason.present?

      @album.update!(
        status: @status,
        reconciliation_status: @reconciliation_status,
        transfer_bill_image: total_image,
        transfer_amount_vnd: total_amount,
        child_total_vnd: @child_total,
        child_count: @child_count,
        transfer_count: @total_count,
        match_difference_vnd: difference_vnd(total_amount),
        metadata: metadata
      )

      AuditLogger.log!(
        action: "bill_album.reconciled", auditable: @album,
        after_data: { "status" => @status, "reconciliation_status" => @reconciliation_status }
      )
      StructuredLog.info("bill_album.reconciled", bill_album_id: @album.id, status: @status,
                                                 reconciliation_status: @reconciliation_status)
    end

    def difference_vnd(total_amount)
      return nil unless @reconciliation_status == "mismatched" && total_amount

      @child_total - total_amount
    end
  end
end
