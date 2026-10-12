class Remitter < ApplicationRecord
  TelegramSender = Data.define(:id, :name, :username) do
    def label = [ name, username && "@#{username}" ].compact.join(" ")
  end

  has_many :remitter_transfers, dependent: :restrict_with_error

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

  # People who wrote in the groups recently and are not a remitter yet: the
  # client picks one instead of looking up a Telegram user id.
  def self.telegram_sender_suggestions(since: 60.days.ago, limit: 50)
    TelegramMessage.where(created_at: since..).where.not(telegram_sender_id: nil)
      .where.not(telegram_sender_id: where.not(telegram_user_id: nil).select(:telegram_user_id))
      .group(:telegram_sender_id)
      .order(Arel.sql("MAX(telegram_messages.id) DESC")).limit(limit)
      .pluck(:telegram_sender_id, Arel.sql("MAX(telegram_messages.sender_name)"),
             Arel.sql("MAX(telegram_messages.telegram_username)"))
      .map { |id, name, username| TelegramSender.new(id: id, name: name, username: username) }
  end

  private

  # The column header in the "thu chi" tab defaults to the name in capitals
  # (Lập -> LẬP); the username is taken from the person's Telegram messages.
  def normalize_fields
    self.excel_key = (excel_key.presence || name).to_s.strip.upcase.presence
    self.telegram_username = telegram_username.to_s.strip.delete_prefix("@").downcase.presence
    if telegram_username.nil? && telegram_user_id.present?
      self.telegram_username = TelegramMessage.where(telegram_sender_id: telegram_user_id)
                                              .where.not(telegram_username: nil).order(id: :desc).pick(:telegram_username)
    end
  end
end
