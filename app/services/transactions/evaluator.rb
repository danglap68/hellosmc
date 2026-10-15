module Transactions
  # Evaluates one normalized settlement document: resolves dealer, merchant,
  # card type and fee rule, calculates amounts and lists every reason the
  # result cannot be auto-approved. Pure: it does not persist anything.
  class Evaluator
    FUTURE_TOLERANCE = 1.hour

    Evaluation = Data.define(:attributes, :review_reasons, :source_data)

    def self.call(document:, bill_image:)
      new(document:, bill_image:).call
    end

    def initialize(document:, bill_image:)
      @doc = document
      @bill_image = bill_image
      @reasons = BillVision::ImageIntegrity.blocking_reasons(@doc["vision_review_reasons"])
    end

    def call
      @reasons << "too_many_documents" if @bill_image.normalized_extraction.to_h["documents_truncated"].to_i.positive?
      check_document_type
      amount = check_amount
      transaction_at = check_transaction_time
      merchant, merchant_result = check_merchant
      @dealer_result = check_dealer(merchant)
      dealer = @dealer_result.dealer
      card_type_result = check_card_type(merchant, dealer)
      fee_result = check_fee_rule(merchant, dealer, card_type_result.card_type, transaction_at)
      base_fee = base_fee_for(fee_result.fee_rule, merchant, dealer, card_type_result.card_type, transaction_at)
      @reasons << base_fee.review_reason if base_fee.review_reason
      calculation = calculate(amount, fee_result.fee_rule, base_fee)

      attributes = {
        dealer: dealer,
        merchant: merchant,
        card_type: card_type_result.card_type,
        fee_rule: fee_result.fee_rule,
        lot_number: @doc["lot_number"],
        transaction_at: transaction_at,
        transaction_amount_vnd: amount,
        confidence_score: @doc["critical_confidence"],
        **calculation_attributes(calculation, fee_result.fee_rule, base_fee,
                                 FeeRules::Resolver.household_base_fee_rate(merchant: merchant, at: transaction_at))
      }

      Evaluation.new(
        attributes: attributes,
        review_reasons: @reasons.uniq,
        source_data: source_data(merchant_result, card_type_result, fee_result)
      )
    end

    private

    def check_document_type
      case @doc["document_type"]
      when "settlement"
        flag_confidence("document_type", "document_type")
      when "child_receipt"
        @reasons << "document_type_uncertain"
      else
        @reasons << "document_type_unknown"
      end
    end

    def check_amount
      amount = @doc["total_amount_vnd"]
      if amount.nil?
        @reasons << "amount_missing"
      else
        flag_confidence("total_amount_vnd", "amount")
      end
      amount
    end

    def check_transaction_time
      transaction_at = @doc["transaction_at"].present? ? Time.zone.parse(@doc["transaction_at"]) : nil
      if transaction_at.nil?
        @reasons << "transaction_time_missing"
        return nil
      end

      flag_confidence("transaction_date", "transaction_date", corroborated: date_matches_submission?(transaction_at))
      flag_confidence("transaction_time", "transaction_time")
      if transaction_at > Time.current + FUTURE_TOLERANCE || transaction_at < AppConfig.max_receipt_age_days.days.ago
        @reasons << "transaction_date_out_of_range"
      end
      transaction_at
    end

    def check_dealer(merchant)
      # The agent is only meaningful once the HKD is known; a missing merchant
      # is already reported as merchant_missing / merchant_not_found.
      return Dealers::Resolver::Result.new(dealer: nil, merchant_dealer: nil, source: nil, issue: nil) if merchant.nil?

      result = Dealers::Resolver.call(merchant: merchant, merchant_name: @doc["merchant_name"],
                                      recipient_name: @doc["recipient_name"])
      @reasons << result.issue if result.issue
      # A name match alone never approves a bill: a person confirms the agent.
      @reasons << "dealer_from_recipient" if result.source == "recipient" && result.issue.nil?
      result
    end

    def check_merchant
      result = resolve_merchant

      @reasons << "merchant_bank_missing" if bank_missing?(result)
      if result.exact? || accepted_near_match?(result)
        source_field = result.method == :identifier ? "terminal_or_merchant_id" : "merchant_name"
        flag_confidence(source_field, "merchant")
      elsif result.method.in?(%i[ai_match ai_conflict ai_uncertain])
        @reasons << "merchant_#{result.method}"
      elsif result.fuzzy?
        @reasons << "merchant_fuzzy_match"
      elsif result.ambiguous?
        @reasons << "merchant_ambiguous"
      elsif @doc["merchant_name"].blank? && @doc["terminal_or_merchant_id"].blank?
        @reasons << "merchant_missing"
      else
        @reasons << "merchant_not_found"
      end

      [ result.merchant, result ]
    end

    # Another HKD prints the same name on a bank's slips (alias "<bank> <name>") and this bill shows
    # no bank: which of the two it is cannot be told, a person decides.
    def bank_missing?(result)
      result.exact? && @doc["bill_bank_name"].blank? && Merchants::Resolver.bank_variants_exist?(@doc, result.merchant)
    end

    # A near name match this close is taken as the HKD; below it a person confirms.
    def accepted_near_match?(result)
      result.fuzzy? && result.score.to_f >= AppConfig.merchant_auto_accept_score
    end

    def resolve_merchant
      Merchants::Resolver.for_document(@doc)
    end

    def check_card_type(merchant, dealer)
      result = CardTypes::Resolver.call(
        message_text: @bill_image.message_text,
        explicit_key: @bill_image.manual_card_type_key,
        merchant: merchant,
        dealer: dealer
      )
      @reasons << result.issue if result.issue
      result
    end

    def check_fee_rule(merchant, dealer, card_type, transaction_at)
      result = FeeRules::Resolver.call(merchant: merchant, dealer: dealer, card_type: card_type, at: transaction_at)
      @reasons << "fee_rule_ambiguous" if result.ambiguous?
      @reasons << "fee_rule_not_found" if result.status == :not_found && transaction_at
      result
    end

    def calculate(amount, fee_rule, base_fee)
      return nil unless amount && fee_rule && base_fee.rate

      Calculator.call(transaction_amount_vnd: amount, base_fee_rate: base_fee.rate, dealer_rate: base_fee.dealer_rate)
    end

    def base_fee_for(fee_rule, merchant, dealer, card_type, transaction_at)
      FeeRules::Resolver.amount_base_fee(rule: fee_rule, merchant:, dealer:, card_type:, at: transaction_at)
    end

    def calculation_attributes(calculation, fee_rule, base_fee, household_base_fee_rate)
      return Recalculator.blank_calculation if calculation.nil?

      base_fee_rule = base_fee.rule
      card_base_fee_rate = base_fee.card_rate
      {
        applied_base_fee_rate: fee_rule.base_fee_rate,
        applied_card_base_fee_rate: card_base_fee_rate,
        amount_after_base_fee_vnd: calculation.amount_after_base_fee_vnd,
        applied_dealer_rate: base_fee.dealer_rate,
        dealer_amount_vnd: calculation.dealer_amount_vnd,
        profit_amount_vnd: calculation.profit_amount_vnd,
        calculation_data: calculation.calculation_data.merge(
          "fee_rule" => AuditLogger.serialize(fee_rule.snapshot_attributes),
          "base_fee_rule" => (AuditLogger.serialize(base_fee_rule.snapshot_attributes) if base_fee_rule),
          "card_base_fee_rate" => card_base_fee_rate&.to_s("F"),
          "household_base_fee_rate" => household_base_fee_rate&.to_s("F"),
          "calculated_at" => Time.current.utc.iso8601
        )
      }
    end

    # Below the auto threshold needs review; below the review threshold the
    # value is considered unreadable.
    # corroborated: independent evidence agrees with the value, so a soft score
    # (between the review and auto-approve thresholds) is not worth a human.
    # An unreadable value is always reviewed.
    def flag_confidence(field, reason_prefix, corroborated: false)
      return if Array(@doc["validation_confirmed_fields"]).include?(field)

      confidence = BigDecimal(@doc.dig("confidence", field).to_s.presence || "0")
      if confidence < AppConfig.ocr_review_threshold
        @reasons << "#{reason_prefix}_unreadable"
      elsif confidence < AppConfig.ocr_auto_approve_threshold && !corroborated
        @reasons << "#{reason_prefix}_low_confidence"
      end
    end

    # Settlement bills are posted the day they are printed, or the next morning.
    # A date read that equals that day is confirmed by when the photo arrived
    # (Telegram send time, or upload time for bills uploaded in the admin).
    def date_matches_submission?(transaction_at)
      submitted_at = @bill_image.telegram_message&.sent_at || @bill_image.created_at
      return false unless submitted_at

      (submitted_at.in_time_zone.to_date - transaction_at.in_time_zone.to_date).between?(0, 1)
    end

    def source_data(merchant_result, card_type_result, fee_result)
      {
        "extraction" => @doc,
        "image_integrity" => @bill_image.normalized_extraction.to_h["image_integrity"] || @doc["image_integrity"],
        "message_text" => @bill_image.message_text,
        "ocr_provider" => @bill_image.ocr_provider,
        "ocr_model" => @bill_image.ocr_model,
        "dealer_resolution" => { "source" => @dealer_result.source, "issue" => @dealer_result.issue,
                                 "merchant_dealer_id" => @dealer_result.merchant_dealer&.id },
        "merchant_resolution" => {
          "method" => merchant_result.method.to_s,
          "score" => merchant_result.score,
          "candidate_ids" => merchant_result.candidates.map(&:id),
          "ai_suggestion" => ai_suggestion(merchant_result)
        },
        "card_type_resolution" => {
          "source" => card_type_result.source,
          "detected_keys" => card_type_result.detected_keys,
          "issue" => card_type_result.issue
        },
        "fee_rule_resolution" => {
          "status" => fee_result.status.to_s,
          "level" => fee_result.level,
          "candidate_ids" => fee_result.candidates.map(&:id)
        }
      }
    end

    def ai_suggestion(merchant_result)
      match = @doc["merchant_match"]
      return unless match.is_a?(Hash)

      merchant = merchant_result.candidates.find { |candidate| candidate.id == match["merchant_id"] }
      match.merge("name" => merchant&.name)
    end
  end
end
