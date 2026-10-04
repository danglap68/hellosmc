class User < ApplicationRecord
  # Public registration is intentionally not enabled; admins create users.
  devise :database_authenticatable, :recoverable, :rememberable, :validatable,
         :trackable, :lockable, :timeoutable

  ROLES = %w[admin operator viewer].freeze

  enum :role, ROLES.index_by(&:itself), validate: true

  has_many :approved_transactions, class_name: "Transaction", foreign_key: :approved_by_id,
    inverse_of: :approved_by, dependent: :restrict_with_error

  validates :name, length: { maximum: 120 }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:email) }

  def active_for_authentication?
    super && active?
  end

  def inactive_message
    active? ? super : :account_inactive
  end

  def display_name
    name.presence || email
  end
end
