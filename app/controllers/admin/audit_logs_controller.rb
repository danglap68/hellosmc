module Admin
  class AuditLogsController < BaseController
    permission :audit_logs

    def index
      scope = AuditLog.includes(:actor_user).recent_first
      scope = scope.where(actor_type: "System") if params[:actor] == "system"
      scope = scope.where(actor_type: "User", actor_id: params[:actor]) if params[:actor].to_s.match?(/\A\d+\z/)
      scope = scope.where(auditable_type: params[:entity]) if params[:entity].present?
      scope = scope.where(auditable_id: params[:entity_id]) if params[:entity_id].present?
      scope = scope.where(action: params[:action_name]) if params[:action_name].present?
      scope = scope.where(created_at: parse_day(params[:date_from])..) if parse_day(params[:date_from])
      scope = scope.where(created_at: ..parse_day(params[:date_to]).end_of_day) if parse_day(params[:date_to])
      @pagy, @audit_logs = pagy(scope, limit: 50)
      @actions = AuditLog.distinct.order(:action).pluck(:action)
      @entities = AuditLog.where.not(auditable_type: nil).distinct.order(:auditable_type).pluck(:auditable_type)
      @users = User.ordered
    end

    def show
      @audit_log = AuditLog.find(params[:id])
    end

    private

    def parse_day(value)
      return nil if value.blank?

      date = Date.iso8601(value)
      Time.zone.local(date.year, date.month, date.day)
    rescue Date::Error
      nil
    end
  end
end
