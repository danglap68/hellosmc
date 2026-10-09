module Transactions
  # Applies a reviewer's corrections, recalculates deterministically and
  # records before/after in the audit log. Used by "Save draft", the edit
  # form, and as the first step of "Save & approve".
  #
  # The fee rule is re-resolved only when an input of the resolution changed
  # (merchant, dealer, card type, time), when the reviewer picks a rule, or
  # when no rate was applied yet; otherwise the snapshotted rate is kept.
  class Corrector
    FIELDS = %w[dealer_id merchant_id card_type_id transaction_amount_vnd lot_number
                transaction_date transaction_time fee_rule_id].freeze
    PERMITTED = (FIELDS + [ "lock_version" ]).freeze

    Result = Data.define(:success, :changed_fields) do
      def success?
        success
      end
    end

    def self.call(transaction:, actor:, params:, note: nil)
      new(transaction:, actor:, params:, note:).call
    end

    def initialize(transaction:, actor:, params:, note:)
      @transaction = transaction
      @actor = actor
      @params = params.to_h.stringify_keys.slice(*PERMITTED)
      @note = note.presence
    end

    def call
      Transaction.transaction do
        @transaction.lock!
        return failure(:base, :not_editable) unless @transaction.editable?
        return failure(:base, :stale) if stale?

        before = @transaction.audit_snapshot
        assign_values
        raise ActiveRecord::Rollback if @transaction.errors.any?

        Recalculator.call(@transaction, fee_rule_override: fee_rule_override, resolve: resolve_fee_rule?)
        sync_card_fee_reason
        changed = @transaction.changed - %w[updated_at calculation_data lock_version source_data]
        record_correction(changed)
        @transaction.save!
        @transaction.transition_to!("needs_review") if @transaction.failed?
        update_review(changed)

        if changed.any? || @note
          AuditLogger.log!(actor: @actor, action: "transaction.corrected", auditable: @transaction,
                           before_data: before, after_data: @transaction.audit_snapshot,
                           metadata: { "changed_fields" => changed, "note" => @note }.compact)
        end
        return Result.new(success: true, changed_fields: changed)
      end
      Result.new(success: false, changed_fields: [])
    rescue ActiveRecord::RecordInvalid
      Result.new(success: false, changed_fields: [])
    end

    private

    def failure(attribute, error)
      @transaction.errors.add(attribute, error)
      Result.new(success: false, changed_fields: [])
    end

    # The form carries the lock_version it was rendered with.
    def stale?
      @params["lock_version"].present? && @params["lock_version"].to_i != @transaction.lock_version
    end

    def resolve_fee_rule?
      return true if fee_rule_override
      return true if @transaction.applied_base_fee_rate.nil?
      return true if (@transaction.changed & Recalculator::RESOLUTION_INPUTS).any?

      # Choosing "automatic" again removes a previous manual override.
      @params.key?("fee_rule_id") && @params["fee_rule_id"].blank? &&
        @transaction.calculation_data["fee_rule_source"] == "override"
    end

    def assign_values
      assign_reference(:dealer, Dealer) if @params.key?("dealer_id")
      assign_reference(:merchant, Merchant) if @params.key?("merchant_id")
      assign_reference(:card_type, CardType) if @params.key?("card_type_id")
      @transaction.lot_number = @params["lot_number"].to_s.strip.presence if @params.key?("lot_number")
      assign_amount if @params.key?("transaction_amount_vnd")
      assign_time if @params.key?("transaction_date") || @params.key?("transaction_time")
    end

    def assign_reference(name, model)
      id = @params["#{name}_id"].presence
      record = id && model.find_by(id: id)
      @transaction.errors.add(:"#{name}_id", :invalid) if id && record.nil?
      @transaction.public_send("#{name}=", record)
    end

    # Accepts "11.445.000", "11,445,000" or "11445000".
    def assign_amount
      raw = @params["transaction_amount_vnd"].to_s.strip
      if raw.blank?
        @transaction.transaction_amount_vnd = nil
      elsif raw.match?(/\A\d{1,3}([.,\s]?\d{3})*\z/) || raw.match?(/\A\d+\z/)
        @transaction.transaction_amount_vnd = raw.gsub(/\D/, "").to_i
      else
        @transaction.errors.add(:transaction_amount_vnd, :not_a_number)
      end
    end

    def assign_time
      date_text = @params["transaction_date"].to_s.strip
      time_text = @params["transaction_time"].to_s.strip
      if date_text.blank? && time_text.blank?
        @transaction.transaction_at = nil
        return
      end

      date = Date.iso8601(date_text)
      match = time_text.match(/\A(\d{1,2}):(\d{2})(?::(\d{2}))?\z/)
      raise ArgumentError unless match

      @transaction.transaction_at = Time.zone.local(date.year, date.month, date.day,
                                                    match[1].to_i, match[2].to_i, match[3].to_i)
    rescue ArgumentError, Date::Error
      @transaction.errors.add(:transaction_at, :invalid)
    end

    def fee_rule_override
      id = @params["fee_rule_id"].presence
      return nil unless id

      @fee_rule_override ||= FeeRule.active.find_by(id: id)
    end

    # `card_fee_rule_applied` describes how the amount is priced right now, so it follows the
    # recalculated result instead of staying from OCR time.
    def sync_card_fee_reason
      reasons = @transaction.review_reason_codes
      applies = @transaction.fee_rule&.fee_rule_merchants&.any? && @transaction.applied_card_base_fee_rate.present?
      updated = applies ? reasons | [ "card_fee_rule_applied" ] : reasons - [ "card_fee_rule_applied" ]
      return if updated == reasons

      @transaction.source_data = @transaction.source_data.merge("review_reasons" => updated)
    end

    def record_correction(changed)
      return if changed.empty?

      corrections = Array(@transaction.source_data["manual_corrections"])
      corrections << { "by" => @actor&.id, "at" => Time.current.utc.iso8601, "fields" => changed }
      @transaction.source_data = @transaction.source_data.merge("manual_corrections" => corrections)
    end

    def update_review(changed)
      review = @transaction.open_review
      return unless review

      corrected = review.corrected_values.merge(
        @transaction.slice(*changed.map(&:to_s)).transform_values { |value| AuditLogger.serialize("v" => value)["v"] }
      )
      review.update!(corrected_values: corrected, note: @note || review.note)
    end
  end
end
