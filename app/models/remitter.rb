class Remitter < ApplicationRecord
  before_validation :normalize_fields

  validates :name, presence: true, length: { maximum: 80 }
  validates :excel_key, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 40 }
  validates :telegram_user_id, uniqueness: true, allow_nil: true
  validates :telegram_username, uniqueness: { case_sensitive: false }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:id) }

  def display_name
    name
  end

  private

  def normalize_fields
    self.excel_key = excel_key.to_s.strip.upcase.presence
    self.telegram_username = telegram_username.to_s.strip.delete_prefix("@").downcase.presence
  end
end
