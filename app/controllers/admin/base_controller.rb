module Admin
  class BaseController < ApplicationController
    include Pagy::Backend

    READ_ACTIONS = %w[index show download].freeze

    layout "admin"

    before_action :authenticate_user!
    before_action :authorize_access!

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
      Permissions.allowed?(current_user, ability, resource)
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
  end
end
