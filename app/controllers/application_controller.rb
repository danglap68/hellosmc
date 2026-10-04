class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  layout :layout_by_resource

  private

  def layout_by_resource
    devise_controller? ? "auth" : "application"
  end

  def after_sign_in_path_for(resource)
    stored_location_for(resource) || admin_root_path
  end

  def after_sign_out_path_for(_resource_or_scope)
    new_user_session_path
  end
end
