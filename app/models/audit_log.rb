class AuditLog < ApplicationRecord
  ACTOR_TYPES = %w[User System].freeze

  belongs_to :actor_user, class_name: "User", foreign_key: :actor_id, optional: true
  belongs_to :auditable, polymorphic: true, optional: true

  validates :actor_type, inclusion: { in: ACTOR_TYPES }
  validates :action, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  # Audit entries are append-only.
  def readonly?
    persisted?
  end

  def system?
    actor_type == "System"
  end

  def actor_name
    system? ? nil : actor_user&.display_name
  end

  def changed_keys
    before = before_data || {}
    after = after_data || {}
    (before.keys | after.keys).select { |key| before[key] != after[key] }
  end
end
