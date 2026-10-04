module BillImages
  # Runs vision extraction for one BillImage and stores both the raw provider
  # output and the normalized extraction. Never loses the raw output.
  class Analyzer
    Result = Data.define(:status, :bill_image)

    # A run claimed by another job is considered abandoned after this long.
    STALE_AFTER = 15.minutes

    # job_id identifies the run: retries of the same job continue the same
    # run (one ocr_attempt), a different job is a new run.
    def self.call(bill_image, force: false, job_id: nil, extractor: BillVision::Extractor)
      new(bill_image, force: force, job_id: job_id, extractor: extractor).call
    end

    def initialize(bill_image, force:, job_id:, extractor:)
      @bill_image = bill_image
      @force = force
      @job_id = job_id
      @extractor = extractor
    end

    def call
      skip = claim
      return Result.new(status: skip, bill_image: @bill_image) if skip

      log("ocr.request")
      vision = @extractor.call(image: @bill_image)
      normalized = BillVision::Normalizer.call(vision.data, provider: vision.provider, model: vision.model)

      @bill_image.update!(
        raw_extraction: vision.raw,
        normalized_extraction: normalized,
        ocr_status: normalized["requires_review"] ? "needs_review" : "completed",
        ocr_provider: vision.provider,
        ocr_model: vision.model,
        ocr_confidence: normalized["min_critical_confidence"],
        analyzed_at: Time.current,
        processing_error: nil
      )
      log("ocr.result", ocr_status: @bill_image.ocr_status, documents: normalized["documents"].size,
                        min_critical_confidence: normalized["min_critical_confidence"])
      Result.new(status: :analyzed, bill_image: @bill_image)
    rescue BillVision::PermanentError => e
      self.class.mark_failed!(@bill_image, e)
      Result.new(status: :failed, bill_image: @bill_image)
    rescue BillVision::TransientError => e
      record_transient(e)
      raise
    rescue StandardError => e
      # Storage, network or unexpected errors: retry like a transient failure,
      # so the bill ends up failed (and visible) instead of stuck in processing.
      error = BillVision::TransientError.new("#{e.class.name}: #{e.message}")
      record_transient(error)
      raise error
    end

    def self.mark_failed!(bill_image, error)
      bill_image.update!(ocr_status: "failed", processing_error: error.message.truncate(2000))
      StructuredLog.error("ocr.failed", bill_image_id: bill_image.id, error_class: error.class.name,
                                        error: error.message.truncate(300))
    end

    private

    def record_transient(error)
      @bill_image.update_columns(processing_error: error.message.truncate(2000), updated_at: Time.current)
      log("ocr.transient_error", error: error.message.truncate(300))
    end

    # Returns a skip reason, or nil when this run owns the analysis.
    def claim
      @bill_image.with_lock do
        return :duplicate if @bill_image.ocr_duplicate? || @bill_image.duplicate_of_id.present?
        return :no_image unless @bill_image.image.attached?
        return :already_analyzed if !@force && (@bill_image.ocr_completed? || @bill_image.ocr_needs_review?)

        claimed_by = @bill_image.metadata["ocr_claim"]
        same_run = @bill_image.ocr_processing? && @job_id.present? && claimed_by == @job_id
        if @bill_image.ocr_processing? && !same_run && claimed_by.present? && @bill_image.updated_at > STALE_AFTER.ago
          return :in_progress
        end

        @bill_image.update!(
          ocr_status: "processing",
          ocr_attempts: @bill_image.ocr_attempts + (same_run ? 0 : 1),
          metadata: @bill_image.metadata.merge("ocr_claim" => @job_id || SecureRandom.uuid)
        )
      end
      nil
    end

    def log(event, **fields)
      StructuredLog.info(event, bill_image_id: @bill_image.id, provider: AppConfig.vision_provider,
                                telegram_message_id: @bill_image.telegram_message&.telegram_message_id, **fields)
    end
  end
end
