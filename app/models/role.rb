class Role < ApplicationRecord
  SYSTEM = [
    { key: "admin", name: "Quản trị", position: 10 },
    { key: "operator", name: "Vận hành", position: 20 },
    { key: "viewer", name: "Chỉ xem", position: 30 },
    { key: "ke_toan", name: "Kế toán", position: 40 },
    { key: "doi_soat", name: "Đối soát", position: 50 },
    { key: "van_hanh_kho", name: "Vận hành kho", position: 60 }
  ].freeze

  has_many :role_permissions, dependent: :destroy
  has_many :users, foreign_key: :role, primary_key: :key, inverse_of: :access_role

  normalizes :name, with: ->(name) { name.strip }

  before_validation :assign_key_and_position, on: :create
  before_destroy :protect_from_removal

  validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }, length: { maximum: 48 }
  validates :name, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 80 }
  validates :position, presence: true, numericality: { only_integer: true }

  scope :ordered, -> { order(:position, :id) }

  def self.choices
    ordered.pluck(:name, :key)
  end

  def self.build_custom(name)
    new(name: name, system: false)
  end

  # Creates the built-in roles. Existing grants are left alone so a saved change
  # survives a restart. Pass reset_system_grants to restore the starting grants.
  def self.seed_defaults!(reset_system_grants: false)
    SYSTEM.each do |attributes|
      role = find_or_initialize_by(key: attributes[:key])
      if role.new_record?
        role.name = attributes[:name]
        role.position = attributes[:position]
      end
      role.system = true
      role.save!

      next if role.role_permissions.exists? && !reset_system_grants

      role.role_permissions.delete_all
      Permissions.pairs_for(role.key).each do |resource, ability|
        role.role_permissions.create!(resource: resource, ability: ability)
      end
    end
  end

  def locked?
    key == "admin"
  end

  def granted?(resource, ability)
    return true if locked?

    resource = resource.to_s
    ability = ability.to_s
    rows = role_permissions.select { |row| row.resource == resource }
    return true if ability == "read" && rows.any? { |row| row.ability == "manage" }

    rows.any? { |row| row.ability == ability }
  end

  # pairs: [["transactions", "read"], ["transactions", "manage"]]
  # Unknown resources are ignored. Manage always keeps read.
  def replace_grants!(pairs)
    return if locked?

    desired = normalize_pairs(pairs)
    current = role_permissions.pluck(:resource, :ability).sort
    return if current == desired

    transaction do
      role_permissions.delete_all
      desired.each { |resource, ability| role_permissions.create!(resource: resource, ability: ability) }
    end
  end

  def audit_snapshot
    {
      "key" => key,
      "name" => name,
      "grants" => role_permissions.order(:resource, :ability).pluck(:resource, :ability).map { |resource, ability| "#{resource}:#{ability}" }
    }
  end

  private

  def assign_key_and_position
    self.key = generated_key if key.blank?
    self.position = (self.class.maximum(:position) || 0) + 10 if position.to_i.zero?
  end

  def generated_key
    base = VietnameseText.strip_diacritics(name.to_s).downcase.gsub(/[^a-z0-9]+/, "_").delete_prefix("_").delete_suffix("_")
    base = "role" if base.blank?
    base = "role_#{base}" unless base.match?(/\A[a-z]/)
    base = base[0, 40]
    taken = self.class.where("key = :base OR key LIKE :pattern", base: base, pattern: "#{self.class.sanitize_sql_like(base)}\\_%").pluck(:key)
    return base unless taken.include?(base)

    (2..).each { |number| return "#{base}_#{number}" unless taken.include?("#{base}_#{number}") }
  end

  def normalize_pairs(pairs)
    Array(pairs).flat_map { |resource, ability|
      next [] unless Permissions.resource?(resource)

      ability = ability.to_s
      next [] unless RolePermission::ABILITIES.include?(ability)

      ability == "manage" ? [ [ resource.to_s, "read" ], [ resource.to_s, "manage" ] ] : [ [ resource.to_s, "read" ] ]
    }.uniq.sort
  end

  def protect_from_removal
    if locked? || system?
      errors.add(:base, :system_role)
      throw :abort
    elsif users.exists?
      errors.add(:base, :assigned)
      throw :abort
    end
  end
end
