module Admin
  class BaseController < ApplicationController
    include Pagy::Backend

    READ_ACTIONS = %w[index show download].freeze

    layout "admin"

    before_action :authenticate_user!
    before_action :authorize_access!
    before_action :redirect_legacy_settings_index

    helper_method :can?

    rescue_from ActiveRecord::StaleObjectError do
      redirect_back_or_to admin_root_path, alert: t("flash.stale")
    end

    class_attribute :permission_resource

    def self.permission(resource)
      self.permission_resource = resource
    end

    private

    def can?(ability, resource)
      current_user&.can?(ability, resource) || false
    end

    def authorize_access!
      ability = action_name.in?(READ_ACTIONS) ? :read : :manage
      forbid! unless can?(ability, permission_resource)
    end

    # Disk storage (development/test) streams the bytes; R2/S3 redirects to a
    # presigned URL. Compared by name: ActiveStorage only loads the service
    # classes that are configured, so ActiveStorage::Service::DiskService is
    # undefined in production and referencing it raises NameError.
    def disk_storage?(blob)
      blob.service.class.name == "ActiveStorage::Service::DiskService"
    end

    def redirect_legacy_settings_index
      return unless action_name == "index" && request.get?
      return if request.path.start_with?("/admin/settings/")

      helper = SettingsNavHelper::SETTINGS_INDEXES[controller_path]
      return if helper.nil?

      target = public_send(helper)
      target = "#{target}?#{request.query_string}" if request.query_string.present?
      redirect_to target, status: :see_other
    end

    def forbid!
      respond_to do |format|
        format.html { render "admin/shared/forbidden", status: :forbidden }
        format.any { head :forbidden }
      end
    end

    # Logs create/update/destroy of configuration records.
    def audit!(action, record, before: nil, metadata: {})
      AuditLogger.log!(actor: current_user, action: action, auditable: record,
                       before_data: before, after_data: record.destroyed? ? nil : Audit::Snapshot.of(record),
                       metadata: metadata)
    end

    # Whitelisted display order. Unknown keys fall back to the list's existing order.
    def apply_sort(scope, orders, default:)
      key = params[:sort].to_s
      key = default.to_s unless orders.key?(key)
      scope.reorder(orders.fetch(key))
    end

    def apply_active_filter(scope)
      return scope unless params[:active].in?(%w[0 1])

      scope.where(active: params[:active] == "1")
    end

    def apply_time_range(scope, column)
      from = parse_filter_date(params[:date_from])
      to = parse_filter_date(params[:date_to])
      scope = scope.where(column => Time.zone.local(from.year, from.month, from.day)..) if from
      scope = scope.where(column => ..Time.zone.local(to.year, to.month, to.day).end_of_day) if to
      scope
    end

    def apply_date_column_range(scope, column)
      from = parse_filter_date(params[:date_from])
      to = parse_filter_date(params[:date_to])
      scope = scope.where(column => from..) if from
      scope = scope.where(column => ..to) if to
      scope
    end

    def parse_filter_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
  end
end
