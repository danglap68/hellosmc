class RolePermission < ApplicationRecord
  has_paper_trail

  ABILITIES = %w[read manage].freeze

  belongs_to :role

  validates :resource, inclusion: { in: ->(_) { Permissions::RESOURCES.map(&:to_s) } }
  validates :ability, inclusion: { in: ABILITIES }
  validates :resource, uniqueness: { scope: [ :role_id, :ability ] }
end
