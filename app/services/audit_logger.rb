# Explicit, append-only audit trail for financial and configuration changes.
#
#   AuditLogger.log!(actor: current_user, action: "transaction.approved",
#                    auditable: transaction, before_data: before, after_data: after)
#
# actor nil means the system (background processing).
class AuditLogger
  def self.log!(action:, auditable: nil, actor: nil, before_data: nil, after_data: nil, metadata: {})
    AuditLog.create!(
      actor_type: actor.is_a?(User) ? "User" : "System",
      actor_id: actor.is_a?(User) ? actor.id : nil,
      action: action,
      auditable_type: auditable&.class&.base_class&.name,
      auditable_id: auditable&.id,
      before_data: serialize(before_data),
      after_data: serialize(after_data),
      metadata: serialize(metadata) || {}
    )
  end

  # Keeps decimals and times readable and exact in JSON.
  def self.serialize(data)
    return nil if data.nil?

    data.to_h.transform_keys(&:to_s).transform_values do |value|
      case value
      when BigDecimal then value.to_s("F")
      when ActiveSupport::TimeWithZone, Time, DateTime then value.utc.iso8601
      when Date then value.iso8601
      when Hash then serialize(value)
      else value
      end
    end
  end
end
