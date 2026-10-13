class User < ApplicationRecord
  # Public registration is intentionally not enabled; admins create users.
  devise :database_authenticatable, :recoverable, :rememberable, :validatable,
         :trackable, :lockable, :timeoutable

  belongs_to :access_role, class_name: "Role", foreign_key: :role, primary_key: :key, optional: true, inverse_of: :users

  has_many :approved_transactions, class_name: "Transaction", foreign_key: :approved_by_id,
    inverse_of: :approved_by, dependent: :restrict_with_error

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
