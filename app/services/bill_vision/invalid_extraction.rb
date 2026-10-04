module BillVision
  # A response was received, but it cannot be used as factual extraction.
  # Keep its usage/raw body for audit; never retry a truncated output.
  class InvalidExtraction < PermanentError
    attr_reader :raw, :model, :reason

    def initialize(message, raw:, model:, reason: "malformed_primary_extraction")
      super(message)
      @raw, @model, @reason = raw, model, reason
    end
  end
end
