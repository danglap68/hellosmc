module Audit
  # Business-relevant attributes of a record for before/after audit data.
  module Snapshot
    IGNORED = %w[created_at updated_at encrypted_password reset_password_token unlock_token
                 normalized_name normalized_alias].freeze

    module_function

    def of(record)
      return nil if record.nil?
      return record.audit_snapshot if record.respond_to?(:audit_snapshot)

      record.attributes.except(*IGNORED)
    end
  end
end
