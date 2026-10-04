# Role-based access matrix.
#   admin    - everything
#   operator - transactions, review queue, uploads, exports; reads configuration
#   viewer   - read-only dashboard, transactions and reports
module Permissions
  MATRIX = {
    "admin" => :all,
    "operator" => {
      manage: %i[transactions reviews bill_uploads excel_exports],
      read: %i[dashboard bill_images dealers telegram_chats merchants fee_rules card_types audit_logs]
    },
    "viewer" => {
      manage: [],
      read: %i[dashboard transactions bill_images excel_exports]
    }
  }.freeze

  module_function

  # ability: :read or :manage
  def allowed?(user, ability, resource)
    return false unless user&.active?

    rules = MATRIX.fetch(user.role)
    return true if rules == :all
    return true if rules[:manage].include?(resource)

    ability == :read && rules[:read].include?(resource)
  end
end
