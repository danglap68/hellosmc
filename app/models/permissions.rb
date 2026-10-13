# What each role may do. Resources are the admin screens; abilities are read and manage.
# Manage includes read. The admin role is always allowed everything, so the matrix
# cannot lock the last administrator out of the app.
module Permissions
  ABILITIES = %i[read manage].freeze

  GROUPS = [
    {
      key: :daily,
      resources: %i[dashboard messages transactions reviews remitter_transfers bill_albums bill_images bill_uploads excel_exports].freeze
    },
    {
      key: :organization,
      resources: %i[dealers telegram_chats merchants remitters transfer_codes].freeze
    },
    {
      key: :fees,
      resources: %i[fee_rules card_types].freeze
    },
    {
      key: :system,
      resources: %i[settings users roles audit_logs].freeze
    }
  ].freeze

  RESOURCES = GROUPS.flat_map { |group| group[:resources] }.freeze

  # Starting grants. An administrator can change every role except admin.
  # Operator and viewer match the access the app enforced before grants were stored,
  # plus read access to the message log for operators.
  DEFAULT_GRANTS = {
    "admin" => :all,
    "operator" => {
      manage: %i[transactions reviews remitter_transfers bill_uploads excel_exports].freeze,
      read: %i[dashboard messages bill_images bill_albums dealers telegram_chats merchants fee_rules remitters card_types audit_logs].freeze
    },
    "viewer" => {
      manage: [].freeze,
      read: %i[dashboard transactions remitter_transfers bill_images bill_albums excel_exports].freeze
    },
    "ke_toan" => {
      manage: %i[excel_exports].freeze,
      read: %i[dashboard transactions fee_rules card_types audit_logs dealers merchants remitter_transfers].freeze
    },
    "doi_soat" => {
      manage: %i[reviews remitter_transfers].freeze,
      read: %i[dashboard messages transactions bill_albums bill_images dealers merchants remitters].freeze
    },
    "van_hanh_kho" => {
      manage: %i[bill_uploads remitter_transfers].freeze,
      read: %i[dashboard messages transactions bill_albums bill_images dealers merchants remitters].freeze
    }
  }.freeze

  NONE = { manage: [].freeze, read: [].freeze }.freeze

  module_function

  def resource?(value)
    (value.is_a?(String) || value.is_a?(Symbol)) && RESOURCES.include?(value.to_sym)
  end

  def pairs_for(role_key)
    rules = DEFAULT_GRANTS.fetch(role_key)
    return RESOURCES.flat_map { |resource| ABILITIES.map { |ability| [ resource.to_s, ability.to_s ] } } if rules == :all

    pairs = []
    rules.fetch(:manage).each do |resource|
      pairs << [ resource.to_s, "read" ]
      pairs << [ resource.to_s, "manage" ]
    end
    rules.fetch(:read).each { |resource| pairs << [ resource.to_s, "read" ] }
    pairs.uniq
  end

  def allowed?(user, ability, resource)
    return false unless user&.active?

    allow_snapshot?(user.permission_snapshot, ability, resource)
  end

  def snapshot_for(role_key)
    return :all if role_key == "admin"
    return NONE if role_key.blank?

    manage = []
    read = []
    RolePermission.joins(:role).where(roles: { key: role_key }).pluck(:resource, :ability).each do |resource, ability|
      next unless resource?(resource)

      (ability == "manage" ? manage : read) << resource.to_sym
    end
    { manage: manage.uniq.freeze, read: read.uniq.freeze }
  end

  def allow_snapshot?(snapshot, ability, resource)
    resource = resource.to_sym
    ability = ability.to_sym
    return false unless RESOURCES.include?(resource) && ABILITIES.include?(ability)
    return true if snapshot == :all
    return true if snapshot[:manage].include?(resource)

    ability == :read && snapshot[:read].include?(resource)
  end
end
