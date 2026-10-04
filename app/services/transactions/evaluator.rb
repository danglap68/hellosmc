module Transactions
  # Evaluates one normalized settlement document: resolves dealer, merchant,
  # card type and fee rule, calculates amounts and lists every reason the
  # result cannot be auto-approved. Pure: it does not persist anything.
  class Evaluator
    FUTURE_TOLERANCE = 1.hour

    Evaluation = Data.define(:attributes, :review_reasons, :source_data)

    def self.call(document:, bill_image:, dealer_result: nil)
      new(document:, bill_image:, dealer_result:).call
    end

    def initialize(document:, bill_image:, dealer_result: nil)
      @doc = document
      @bill_image = bill_image
      @dealer_result = dealer_result || Dealers::Resolver.call(bill_image: bill_image)
      @reasons = Array(@doc["vision_review_reasons"]).dup
    end

    def call
      @reasons << "too_many_documents" if @bill_image.normalized_extraction.to_h["documents_truncated"].to_i.positive?
      check_document_type
      amount = check_amount
      transaction_at = check_transaction_time
      dealer = check_dealer
      merchant, merchant_result = check_merchant(dealer)
      card_type_result = check_card_type(merchant, dealer)
      fee_result = check_fee_rule(merchant, dealer, card_type_result.card_type, transaction_at)
      calculation = calculate(amount, fee_result.fee_rule)

      attributes = {
        dealer: dealer,
        merchant: merchant,
        card_type: card_type_result.card_type,
        fee_rule: fee_result.fee_rule,
        lot_number: @doc["lot_number"],
        transaction_at: transaction_at,
        transaction_amount_vnd: amount,
        confidence_score: @doc["critical_confidence"],
        **calculation_attributes(calculation, fee_result.fee_rule)
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

      flag_confidence("transaction_date", "transaction_date")
      flag_confidence("transaction_time", "transaction_time")
      if transaction_at > Time.current + FUTURE_TOLERANCE || transaction_at < AppConfig.max_receipt_age_days.days.ago
        @reasons << "transaction_date_out_of_range"
      end
      transaction_at
    end

    def check_dealer
      @reasons << @dealer_result.issue if @dealer_result.issue
      @dealer_result.dealer
    end

    def check_merchant(dealer)
      result = Merchants::Resolver.call(
        merchant_name: @doc["merchant_name"],
        merchant_identifier: @doc["terminal_or_merchant_id"],
        dealer: dealer
      )

      if result.exact?
        source_field = result.method == :identifier ? "terminal_or_merchant_id" : "merchant_name"
        flag_confidence(source_field, "merchant")
      elsif result.fuzzy?
        @reasons << "merchant_fuzzy_match"
      elsif result.ambiguous?
        @reasons << "merchant_ambiguous"
      elsif @doc["merchant_name"].blank? && @doc["terminal_or_merchant_id"].blank?
        @reasons << "merchant_missing"
      else
        @reasons << "merchant_not_found"
      end

      merchant = result.merchant
      if merchant && dealer && merchant.dealer_id.present? && merchant.dealer_id != dealer.id
        @reasons << "merchant_dealer_mismatch"
      end
      [ merchant, result ]
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

    def calculate(amount, fee_rule)
      return nil unless amount && fee_rule

      Calculator.call(transaction_amount_vnd: amount, base_fee_rate: fee_rule.base_fee_rate,
                      dealer_rate: fee_rule.dealer_rate)
    end

    def calculation_attributes(calculation, fee_rule)
      return Recalculator.blank_calculation if calculation.nil?

      {
        applied_base_fee_rate: fee_rule.base_fee_rate,
        amount_after_base_fee_vnd: calculation.amount_after_base_fee_vnd,
        applied_dealer_rate: fee_rule.dealer_rate,
        dealer_amount_vnd: calculation.dealer_amount_vnd,
        profit_amount_vnd: calculation.profit_amount_vnd,
        calculation_data: calculation.calculation_data.merge(
          "fee_rule" => AuditLogger.serialize(fee_rule.snapshot_attributes),
          "calculated_at" => Time.current.utc.iso8601
        )
      }
    end

    # Below the auto threshold needs review; below the review threshold the
    # value is considered unreadable.
    def flag_confidence(field, reason_prefix)
      return if Array(@doc["validation_confirmed_fields"]).include?(field)

      confidence = BigDecimal(@doc.dig("confidence", field).to_s.presence || "0")
      if confidence < AppConfig.ocr_review_threshold
        @reasons << "#{reason_prefix}_unreadable"
      elsif confidence < AppConfig.ocr_auto_approve_threshold
        @reasons << "#{reason_prefix}_low_confidence"
      end
    end

    def source_data(merchant_result, card_type_result, fee_result)
      {
        "extraction" => @doc,
        "message_text" => @bill_image.message_text,
        "ocr_provider" => @bill_image.ocr_provider,
        "ocr_model" => @bill_image.ocr_model,
        "dealer_resolution" => { "source" => @dealer_result.source, "issue" => @dealer_result.issue },
        "merchant_resolution" => {
          "method" => merchant_result.method.to_s,
          "score" => merchant_result.score,
          "candidate_ids" => merchant_result.candidates.map(&:id)
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
  end
end
