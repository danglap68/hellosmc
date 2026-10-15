module BillImages
  # Only system-caused review states are eligible. One enqueue per completed
  # run, image/row locks and the existing lifetime OCR budget bound recovery.
  class SystemRecovery
    OCR_REASONS = %w[model_disagreement malformed_primary_extraction primary_output_truncated validator_failed
                     document_missing_after_reprocess].freeze
    CATALOG_REASONS = %w[merchant_ai_conflict merchant_ai_uncertain].freeze

    def self.call(bill_image, expected_run_id: nil)
      new(bill_image, expected_run_id).call
    end

    def initialize(image, expected_run_id)
      @image, @expected_run_id = image, expected_run_id
    end

    def call
      mode = nil
      @image.with_lock do
        pipeline = @image.metadata["vision_pipeline"].to_h
        return :stale if @expected_run_id && pipeline["run_id"] != @expected_run_id
        return :skipped if @image.duplicate_of_id || @image.ocr_processing? || !@image.image.attached?

        rows = @image.transactions.order(:id).lock.to_a
        return :skipped if rows.empty? || rows.any? { |row| protected?(row) }

        mode = recovery_mode(rows)
        return :skipped unless mode
        return :budget_exhausted if mode == "ocr" && !@image.ocr_runs_remaining?

        token = [ mode, pipeline["run_id"], @image.ocr_attempts ].join(":")
        return :already_requested if @image.metadata.dig("system_recovery", "token") == token

        @image.update!(metadata: @image.metadata.merge("system_recovery" => {
          "token" => token, "mode" => mode, "requested_at" => Time.current.iso8601,
          "transaction_ids" => rows.map(&:id), "source_run_id" => pipeline["run_id"]
        }))
        @image.bill_album&.update!(status: "processing", reconciliation_status: nil) if mode == "rebuild"
        rows.each do |row|
          before = row.audit_snapshot.merge("review_reasons" => row.review_reason_codes)
          row.source_data = row.source_data.except("possible_duplicate_ids", "ocr_error").merge("review_reasons" => [])
          row.transition_to!("processing")
          row.reviews.open.update_all(status: "superseded", updated_at: Time.current)
          AuditLogger.log!(action: "transaction.reprocess_requested", auditable: row, before_data: before,
                           after_data: row.audit_snapshot, metadata: { "trigger" => "system_recovery", "mode" => mode })
        end
        id = @image.id
        ActiveRecord.after_all_transactions_commit do
          if mode == "ocr"
            AnalyzeBillImageJob.perform_later(id, force: true)
          else
            AnalyzeBillImageJob.new.build_or_finalize(@image)
          end
        end
      end
      mode.to_sym
    end

    private

    def protected?(row)
      !row.status.in?(%w[needs_review failed]) || row.booked? || row.approved_by_id.present? ||
        row.reviews.where.not(reviewed_by_id: nil).exists? ||
        row.audit_logs.where(actor_type: "User", action: %w[transaction.updated transaction.corrected]).exists?
    end

    def recovery_mode(rows)
      if rows.all? { |row| (row.review_reason_codes & OCR_REASONS).any? }
        "ocr"
      elsif rows.all? { |row| row.review_reason_codes.present? && (row.review_reason_codes - CATALOG_REASONS).empty? }
        # Re-evaluate the stored facts first: configuration resolution requires
        # no new model call and must actually remove the former conflict.
        "rebuild" if rows.all? do |row|
          Transactions::Evaluator.call(document: row.extraction, bill_image: @image).review_reasons.empty?
        end
      end
    end
  end
end
