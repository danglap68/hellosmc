class User < ApplicationRecord
  # Public registration is intentionally not enabled; admins create users.
  devise :database_authenticatable, :recoverable, :rememberable, :validatable,
         :trackable, :lockable, :timeoutable

  has_paper_trail skip: %i[encrypted_password reset_password_token unlock_token],
    ignore: %i[updated_at sign_in_count current_sign_in_at last_sign_in_at current_sign_in_ip last_sign_in_ip
               remember_created_at reset_password_sent_at failed_attempts locked_at]

  belongs_to :access_role, class_name: "Role", foreign_key: :role, primary_key: :key, optional: true, inverse_of: :users

  has_many :approved_transactions, class_name: "Transaction", foreign_key: :approved_by_id,
    inverse_of: :approved_by, dependent: :restrict_with_error
  has_many :confirmed_payment_qrs, class_name: "DealerPaymentQr", foreign_key: :confirmed_by_id,
    inverse_of: :confirmed_by, dependent: :restrict_with_error

  validates :name, length: { maximum: 120 }
  validate :role_is_known

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

  def role_name
    access_role&.name || role
  end

  def admin?
    role == "admin"
  end

  def can?(ability, resource)
    Permissions.allowed?(self, ability, resource)
  end

  # users.manage delegates ordinary accounts, never administrator accounts.
  def manageable_by?(actor)
    actor.can?(:manage, :users) && (actor.admin? || !admin?)
  end

  def permission_snapshot
    @permission_snapshot ||= Permissions.snapshot_for(role)
  end

  def reload(...)
    @permission_snapshot = nil
    super
  end

  def role=(value)
    @permission_snapshot = nil
    super
  end

  private

  def role_is_known
    errors.add(:role, :inclusion) unless role.present? && Role.exists?(key: role)
  end
end
