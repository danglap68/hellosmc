module Roles
  # Saves the grants of one role. The admin role is skipped so a save cannot
  # strip the last full-access account.
  class Matrix
    def self.apply!(actor:, role:, grants:, name: nil)
      new(actor:, role:, grants:, name:).apply!
    end

    def initialize(actor:, role:, grants:, name: nil)
      @actor = actor
      @role = role
      @grants = normalize_hash(grants)
      @name = name
    end

    def apply!
      return if @role.locked?

      Role.transaction do
        before = @role.audit_snapshot
        assign_name
        @role.replace_grants!(pairs)
        @role.save! if @role.changed?
        after = @role.audit_snapshot
        next if before == after

        AuditLogger.log!(
          actor: @actor,
          action: "role.permissions_updated",
          auditable: @role,
          before_data: before,
          after_data: after
        )
      end
    end

    private

    def assign_name
      return if @name.nil?

      @role.name = @name.to_s
    end

    def pairs
      @grants.flat_map do |resource, abilities|
        next [] unless Permissions.resource?(resource)
        next [] unless abilities.is_a?(Hash)

        read = enabled?(abilities["read"])
        manage = enabled?(abilities["manage"])
        next [] unless read || manage

        manage ? [ [ resource.to_s, "read" ], [ resource.to_s, "manage" ] ] : [ [ resource.to_s, "read" ] ]
      end
    end

    def enabled?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def normalize_hash(value)
      hash = case value
      when ActionController::Parameters then value.to_unsafe_h
      when Hash then value
      else {}
      end
      hash.deep_stringify_keys
    end
  end
end