module BulkActions
  class Runner
    LIMIT = 100
    class InvalidSelection < StandardError; end

    def initialize(resource:, operation:, actor:, ids:, versions:, note: nil)
      @resource, @operation, @actor = resource.to_s, operation.to_s, actor
      @config = Catalog::RESOURCES[@resource]
      @ids, @versions, @note = ids, versions, note.to_s.strip
      @reprocess_image_ids = []
    end

    def call
      validate!
      @ids.map { |id| process(id.to_s) }
    ensure
      # Mark every selected settlement before starting one OCR run per image.
      # Also queue already-committed rows if an unexpected later row fails.
      @reprocess_image_ids.uniq.each do |image_id|
        ActiveRecord.after_all_transactions_commit { AnalyzeBillImageJob.perform_later(image_id, force: true) }
      end
    end

    private

    def validate!
      invalid = !@config || !@config[2].include?(@operation) ||
        !@ids.is_a?(Array) || @ids.empty? || @ids.size > LIMIT ||
        !@ids.all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) } ||
        @ids.map(&:to_s).uniq.size != @ids.size || !@versions.is_a?(Hash) ||
        !@ids.all? { |id| @versions[id.to_s].is_a?(String) && @versions[id.to_s].present? }
      raise InvalidSelection, I18n.t("bulk.invalid_selection", limit: LIMIT) if invalid
      raise InvalidSelection, I18n.t("transactions.rejection.required") if @operation == "reject" && @note.blank?
      raise InvalidSelection, I18n.t("bulk.note_too_long") if @note.length > 2_000
      raise InvalidSelection, I18n.t("bulk.forbidden") unless @actor.can?(:manage, @config[1])
    end

    def process(id)
      record = @config[0].find(id)
      message = nil
      record.with_lock do
        if Catalog.version(record) != @versions.fetch(id)
          message = I18n.t("flash.stale")
        else
          message = apply(record)
          # Some domain services return false via a nested Rollback. Roll back
          # the entire row, including any partial edits, before continuing.
          raise ActiveRecord::Rollback if message.present?
        end
      end
      if message.nil? && @resource.in?(%w[transactions reviews]) && @operation == "reprocess"
        @reprocess_image_ids << record.bill_image_id
      end
      { id: id, success: message.nil?, message: message }
    rescue ActiveRecord::RecordNotFound
      { id: id, success: false, message: I18n.t("bulk.missing") }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => error
      { id: id, success: false, message: error.record.errors.full_messages.to_sentence }
    rescue ActiveRecord::InvalidForeignKey
      { id: id, success: false, message: I18n.t("bulk.in_use") }
    rescue ActiveRecord::StaleObjectError
      { id: id, success: false, message: I18n.t("flash.stale") }
    end

    # nil means success, a message means this row was not processed.
    def apply(record)
      return apply_transaction(record) if @resource.in?(%w[transactions reviews])
      return apply_transfer(record) if @resource == "remitter_transfers"
      return process_stored(record) if @operation == "process_stored"

      apply_configuration(record)
    end

    def apply_transaction(record)
      success = case @operation
      when "approve" then Transactions::Approver.call(transaction: record, actor: @actor, note: @note)
      when "hold", "reject" then Transactions::StatusUpdater.call(transaction: record, actor: @actor, action: @operation, note: @note)
      when "reprocess" then Transactions::Reprocessor.call(transaction: record, actor: @actor, enqueue: false)
      end
      record.errors.full_messages.to_sentence.presence || I18n.t("flash.action_failed") unless success
    end

    def apply_transfer(record)
      case @operation
      when "retry"
        result = RemitterTransfers::Retrier.call(transfer: record, actor: @actor, lock_version: record.lock_version)
        I18n.t("remitter_transfers.errors.#{result.error}") unless result.ok?
      when "write"
        return I18n.t("remitter_transfers.errors.not_writable") unless record.writable? && !record.written?

        id = record.id
        ActiveRecord.after_all_transactions_commit { WriteRemitterReportJob.perform_later(id) }
        AuditLogger.log!(actor: @actor, action: "remitter_transfer.write_requested", auditable: record)
        nil
      when "approve", "reject"
        return I18n.t("bulk.transfer_not_reviewable") unless record.status.in?(%w[needs_review failed]) && !record.written?

        result = if @operation == "approve"
          RemitterTransfers::Reviewer.approve(transfer: record, actor: @actor, lock_version: record.lock_version)
        else
          RemitterTransfers::Reviewer.reject(transfer: record, actor: @actor, lock_version: record.lock_version)
        end
        if result.ok?
          AuditLogger.log!(actor: @actor, action: "remitter_transfer.bulk_decision", auditable: record,
                           metadata: { "note" => @note, "decision" => @operation })
          nil
        else
          result.errors.map { |error| I18n.t("remitter_transfers.errors.#{error}") }.to_sentence
        end
      end
    end

    def apply_configuration(record)
      return I18n.t("bulk.forbidden") if record.is_a?(User) && !record.manageable_by?(@actor)
      return I18n.t("users.flash.cannot_delete_self") if record.is_a?(User) && record == @actor && @operation.in?(%w[deactivate destroy])
      return I18n.t("bulk.missing") if @resource == "transfer_codes" && record.transfer_code.blank?

      before = Audit::Snapshot.of(record)
      if @operation == "destroy"
        @resource == "transfer_codes" ? record.update!(transfer_code: nil) : record.destroy!
      else
        record.update!(active: @operation == "activate")
      end
      prefix = @resource == "transfer_codes" ? "transfer_code" : record.model_name.singular
      AuditLogger.log!(actor: @actor, action: "#{prefix}.#{@operation == 'destroy' ? 'destroyed' : 'updated'}",
                       auditable: record, before_data: before,
                       after_data: record.destroyed? ? nil : Audit::Snapshot.of(record), metadata: { "bulk" => true })
      nil
    end

    def process_stored(chat)
      return I18n.t("telegram_chats.flash.activate_first") unless chat.active?

      ids = []
      chat.telegram_messages.stored_unprocessed_images.order(:id).each do |message|
        message.with_lock do
          next unless message.processing_ignored? && message.bill_images.none?

          message.update!(processing_status: "queued")
          id = message.id
          ActiveRecord.after_all_transactions_commit { DownloadTelegramAttachmentJob.perform_later(id) }
          ids << id
        end
      end
      AuditLogger.log!(actor: @actor, action: "telegram_chat.stored_images_processed", auditable: chat,
                       metadata: { "telegram_message_ids" => ids, "bulk" => true })
      nil
    end
  end
end
