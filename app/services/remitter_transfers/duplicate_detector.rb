module RemitterTransfers
  # Keep the evidence used by the approval check available to the reviewer.
  # Identical images and matching payment details are different signals.
  class DuplicateDetector
    Match = Data.define(:transfer, :reasons)
    Result = Data.define(:matches, :original_image, :image_duplicate, :window_minutes) do
      def possible_duplicate? = image_duplicate || matches.any?

      def snapshot
        { "matches" => matches.map { |match| { "id" => match.transfer.id, "reasons" => match.reasons } },
          "original_bill_image_id" => original_image&.id, "image_duplicate" => image_duplicate,
          "window_minutes" => window_minutes }
      end
    end

    def self.call(transfer:, image: transfer.bill_image, amount: transfer.amount_vnd, code: transfer.transfer_code,
                  include_recorded: false)
      new(transfer, image, amount, code, include_recorded).call
    end

    def initialize(transfer, image, amount, code, include_recorded)
      @transfer, @image, @amount, @code, @include_recorded = transfer, image, amount, code, include_recorded
      @window_minutes = AppConfig.duplicate_window_minutes
      @reasons = {}
    end

    def call
      image_duplicate = @image&.ocr_duplicate? || @image&.duplicate_of_id.present? || false
      original = @image&.duplicate_of if image_duplicate
      if original
        RemitterTransfer.where(bill_image_id: original.id)
          .or(RemitterTransfer.where(telegram_message_id: original.telegram_message_id))
          .where.not(id: @transfer.id).find_each { |other| add(other.id, "same_image") }
      end
      match_payment_details

      if @include_recorded && (recorded = @transfer.metadata["duplicate_check"])
        Array(recorded["matches"]).each { |match| Array(match["reasons"]).each { |reason| add(match["id"], reason) } }
        original ||= BillImage.find_by(id: recorded["original_bill_image_id"])
        image_duplicate ||= recorded["image_duplicate"] == true
        @window_minutes = recorded["window_minutes"] || @window_minutes
      end

      matches = RemitterTransfer.where(id: @reasons.keys).includes(:remitter).order(:id).map do |other|
        Match.new(transfer: other, reasons: @reasons.fetch(other.id))
      end
      Result.new(matches: matches, original_image: original, image_duplicate: image_duplicate, window_minutes: @window_minutes)
    end

    private

    def match_payment_details
      return if @amount.nil? || @code.nil? || @transfer.remitter_id.nil?

      window = @window_minutes.minutes
      key = Codes.canonical(@code)
      RemitterTransfer.where(remitter_id: @transfer.remitter_id, amount_vnd: @amount)
        .where.not(id: @transfer.id).where.not(status: %w[rejected failed])
        .where(transferred_at: (@transfer.transferred_at - window)..(@transfer.transferred_at + window))
        .pluck(:id, :transfer_code).each do |id, other_code|
          add(id, "same_payment_details") if Codes.canonical(other_code) == key
        end
    end

    def add(id, reason)
      return if id == @transfer.id

      (@reasons[id] ||= []) << reason unless @reasons.fetch(id, []).include?(reason)
    end
  end
end
