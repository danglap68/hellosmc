module BillVision
  # Count actual outbound requests, including failed requests. Reserve the
  # slot durably BEFORE contacting a provider, so worker crashes cannot reset it.
  class CallBudget
    MAX_PRIMARY_CALLS = 1
    MAX_VALIDATOR_CALLS = 1
    MAX_MODEL_CALLS_PER_RUN = 2
    MAX_OCR_RUNS_PER_BILL = 3
    MAX_OUTPUT_TOKENS = 700

    def initialize(bill_image: nil, run_id: nil)
      @bill_image, @run_id = bill_image, run_id
      @state = { "calls" => { "primary" => 0, "validator" => 0 } }
    end

    def consume!(stage)
      stage = stage.to_s
      limit = { "primary" => MAX_PRIMARY_CALLS, "validator" => MAX_VALIDATOR_CALLS }.fetch(stage)
      mutate do |state|
        calls = state.fetch("calls")
        if calls.fetch(stage) >= limit || calls.values.sum >= MAX_MODEL_CALLS_PER_RUN
          raise BudgetExhausted, "OCR request budget exhausted"
        end
        calls[stage] += 1
      end
    end

    def record!(fields)
      mutate { |state| state.merge!(fields.deep_stringify_keys) }
    end

    def snapshot
      @state.deep_dup
    end

    private

    def mutate
      if @bill_image
        @bill_image.with_lock do
          state = @bill_image.metadata.fetch("vision_pipeline").deep_dup
          unless @bill_image.ocr_processing? && state["run_id"] == @run_id
            raise BudgetExhausted, "OCR run no longer owns this bill"
          end
          yield state
          @bill_image.update!(metadata: @bill_image.metadata.merge("vision_pipeline" => state))
          @state = state
        end
      else
        yield @state
      end
    end
  end
end
