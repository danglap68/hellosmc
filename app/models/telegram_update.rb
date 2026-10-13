class TelegramUpdate < ApplicationRecord
  STATUSES = %w[received processed failed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :update_id, presence: true, uniqueness: true
  validates :payload, presence: true

  # Inserts the webhook body once. Returns the new row id, or nil when this
  # update_id was already stored (Telegram retried and we must not enqueue twice).
  def self.store!(update)
    create!(
      update_id: update["update_id"],
      payload: update,
      received_at: Time.current
    ).id
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue ActiveRecord::RecordInvalid => error
    raise unless error.record.errors.of_kind?(:update_id, :taken)

    nil
  end
end
