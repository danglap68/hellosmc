module RemitterTransfers
  # Retry the unfinished stage without duplicating transfers or reopening a
  # human rejection. Shared duplicate images are never re-analyzed here.
  class Retrier
    COOLDOWN = 30.seconds
    OCR_REASONS = %w[amount_missing amount_ambiguous amount_low_confidence].freeze
    Plan = Data.define(:step, :image, :error) do
      def allowed? = error.nil?
    end
    Result = Data.define(:step, :error) do
      def ok? = error.nil?
    end

    def self.call(transfer:, actor:, lock_version: nil)
      new(transfer, actor, lock_version).call
    end

    def self.plan_for(transfer)
      return Plan.new(step: nil, image: nil, error: :already_written) if transfer.written?
      if transfer.rejected? && (transfer.reviewed_by_human? || transfer.review_reasons.include?("settlement_photo"))
        return Plan.new(step: nil, image: nil, error: :not_retryable)
      end
      last_retry = Time.zone.parse(transfer.metadata["retry_requested_at"]) if transfer.metadata["retry_requested_at"].present?
      if (last_retry && last_retry > COOLDOWN.ago) || (transfer.processing? && transfer.updated_at > BillImages::Analyzer::STALE_AFTER.ago)
        return Plan.new(step: nil, image: nil, error: :retry_in_progress)
      end
      if transfer.approved?
        return Plan.new(step: :write, image: nil, error: (transfer.writable? ? nil : :not_writable))
      end
      return Plan.new(step: nil, image: nil, error: :not_retryable) if transfer.reviewed_by_human?

      image = transfer.bill_image || transfer.telegram_message.bill_images.min_by(&:id)
      unless image
        attachment = Telegram::MessageParser.attachment_from(transfer.telegram_message.raw_message)
        return Plan.new(step: :download, image: nil, error: (attachment ? nil : :retry_image_missing))
      end
      source = image.duplicate_of || image
      return Plan.new(step: nil, image: image, error: :not_retryable) if Classifier.settlement_image?(image)
      if source.ocr_processing? && source.updated_at > BillImages::Analyzer::STALE_AFTER.ago
        return Plan.new(step: nil, image: image, error: :retry_in_progress)
      end

      reread = source.ocr_status.in?(%w[pending processing failed]) || transfer.rejected? ||
        (transfer.review_reasons & OCR_REASONS).any?
      return Plan.new(step: :evaluate, image: image, error: nil) unless reread
      return Plan.new(step: nil, image: image, error: :retry_shared_image) if source != image
      return Plan.new(step: nil, image: image, error: :retry_image_missing) unless image.image.attached?

      Plan.new(step: :ocr, image: image, error: (image.ocr_runs_remaining? ? nil : :retry_budget_exhausted))
    end

    def initialize(transfer, actor, lock_version)
      @transfer, @actor, @lock_version = transfer, actor, lock_version
    end

    def call
      result = nil
      RemitterTransfer.transaction do
        @transfer.lock!
        if @lock_version.present? && @lock_version.to_i != @transfer.lock_version
          result = Result.new(step: nil, error: :stale)
          next
        end
        plan = self.class.plan_for(@transfer)
        result = Result.new(step: plan.step, error: plan.error)
        next unless result.ok?

        before = snapshot
        unless plan.step == :write
          @transfer.status = "processing"
          @transfer.bill_image = plan.image if plan.image
          @transfer.remitter ||= Classifier.remitter_for(sender_id: @transfer.telegram_message.telegram_sender_id,
                                                         username: @transfer.telegram_message.telegram_username)
          @transfer.metadata = @transfer.metadata.merge("retry_requested_at" => Time.current.iso8601, "retry_step" => plan.step.to_s)
          @transfer.save!
        end
        if plan.step == :download
          message = @transfer.telegram_message
          message.update!(processing_status: "queued", raw_payload: message.raw_payload.except("download_error"))
        end
        AuditLogger.log!(actor: @actor, action: "remitter_transfer.retry_requested", auditable: @transfer,
                         before_data: before, after_data: snapshot, metadata: { "step" => plan.step.to_s })
        ActiveRecord.after_all_transactions_commit { enqueue(plan) }
      end
      result
    end

    private

    def enqueue(plan)
      case plan.step
      when :download then DownloadTelegramAttachmentJob.perform_later(@transfer.telegram_message_id)
      when :ocr then AnalyzeBillImageJob.perform_later(plan.image.id, force: true)
      when :evaluate then BuildRemitterTransferJob.perform_later(@transfer.id)
      when :write then WriteRemitterReportJob.perform_later(@transfer.id)
      end
    end

    def snapshot
      @transfer.attributes.slice("status", "bill_image_id", "remitter_id", "transfer_code", "amount_vnd", "review_reasons")
    end
  end
end
