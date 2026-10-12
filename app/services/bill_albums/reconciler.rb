module BillAlbums
  # After every image of an album is OCR'd: sums the child bills (child_receipt,
  # evidence only), builds the single "tổng kết" transaction from a settlement
  # (POS batch closing) or a transfer (bank transfer) — either one accepted
  # dynamically — and reconciles sum(child bills) against that total.
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
      # Several FinalizeBillAlbumJob runs can race once the last image finishes;
      # a row lock + terminal guard makes reconciliation run exactly once.
      @album.with_lock do
        return @album if @album.terminal?

        scan_documents
        build_transactions
        apply_decision
        persist
      end
      @album
    end

    private

    def scan_documents
      @child_total = 0
      @child_count = 0
      @total_count = 0
      @total_amounts = []
      @total_image = nil
      @total_docs = []
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
            amount = doc["total_amount_vnd"]
            next if amount.nil? # a confirm popup / unreadable total is not a "tổng kết"

            @total_count += 1
            @total_amounts << amount
            @total_docs << doc
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

    def build_transactions
      return unless @total_count >= 1

      # The Builder skips child receipts (evidence) and builds the "tổng kết"
      # settlement/transfer as the single transaction. A complete settlement
      # stands on its own: a photo whose OCR failed is skipped, not built as a
      # failed row (it is listed in the album's metadata).
      images = @album.bill_images.analyzable.to_a
      if settlement_complete?
        skipped, images = images.partition(&:ocr_failed?)
        @skipped_failed_image_ids = skipped.map(&:id)
      end
      images.each { |image| Transactions::Builder.call(bill_image: image) }
    end

    def apply_decision
      if @total_count.zero?
        @status = "skipped"
        @reconciliation_status = total_duplicate? ? "transfer_duplicate" : "no_transfer"
        @flag_reason = nil
        @skip_reason = total_duplicate? ? "transfer_duplicate" : nil
      elsif settlement_complete?
        # The bill kết has everything: child bills are dropped, not summed,
        # and a child whose OCR failed does not hold the album back.
        @status = "reconciled"
        @reconciliation_status = "settlement_complete"
        @flag_reason = nil
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
        @flag_reason = "album_missing_bills"
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

    def settlement_complete?
      @total_docs.one? && Transactions::Builder.complete_settlement?(@total_docs.first)
    end

    def persist
      Transactions::Flagger.call(transactions: @album.transactions, reason: @flag_reason) if @flag_reason

      total_amount = @total_count == 1 ? @total_amounts.first : nil
      total_image = @total_count == 1 ? @total_image : nil
      # A re-run starts from a clean slate: what an earlier run recorded about
      # dropped child bills must not outlive it.
      metadata = @album.metadata.except("children_dropped", "skipped_failed_image_ids")
      metadata = metadata.merge("total_amounts" => @total_amounts) if @total_count > 1
      metadata = metadata.merge("skip_reason" => @skip_reason) if @skip_reason.present?
      if @reconciliation_status == "settlement_complete"
        metadata = metadata.merge("children_dropped" => true)
        metadata = metadata.merge("skipped_failed_image_ids" => @skipped_failed_image_ids) if @skipped_failed_image_ids.present?
      end

      # Dropped child bills are not counted, summed or compared: nothing about
      # them is stored for the album.
      dropped = @reconciliation_status == "settlement_complete"
      @album.update!(
        status: @status,
        reconciliation_status: @reconciliation_status,
        transfer_bill_image: total_image,
        transfer_amount_vnd: total_amount,
        child_total_vnd: dropped ? nil : @child_total,
        child_count: dropped ? 0 : @child_count,
        transfer_count: @total_count,
        match_difference_vnd: dropped ? nil : difference_vnd(total_amount),
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
