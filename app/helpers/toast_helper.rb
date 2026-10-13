# Turns flash messages into toasts. Errors stay until dismissed because they
# often carry a long explanation the operator needs to read or copy.
module ToastHelper
  TOAST_TYPES = {
    "success" => { icon: "circle-check", duration: 4000, role: "status" },
    "info" => { icon: "info-circle", duration: 5000, role: "status" },
    "warning" => { icon: "alert-triangle", duration: 8000, role: "alert" },
    "error" => { icon: "alert-circle", duration: 0, role: "alert" }
  }.freeze

  FLASH_TYPES = {
    "notice" => "success",
    "success" => "success",
    "info" => "info",
    "warning" => "warning",
    "alert" => "error",
    "error" => "error"
  }.freeze

  # Devise puts these in flash[:alert] although nothing went wrong.
  DEVISE_ALERT_TYPES = {
    "devise.failure.already_authenticated" => "info",
    "devise.failure.unauthenticated" => "info",
    "devise.failure.timeout" => "warning"
  }.freeze

  def toast_messages
    toasts = flash.filter_map do |key, message|
      type = devise_alert_type(message) if key.to_s == "alert"
      type ||= FLASH_TYPES[key.to_s]
      { type: type, message: message.to_s } if type && message.present?
    end
    if response.status == 422 && toasts.none? { |toast| toast[:type] == "error" }
      toasts << { type: "error", message: t("ui.toast.validation_failed") }
    end
    toasts
  end

  def toast_config(type)
    TOAST_TYPES.fetch(type.to_s, TOAST_TYPES["info"]).merge(title: t("ui.toast.titles.#{type}"))
  end

  def toast_types_json
    TOAST_TYPES.keys.index_with { |type| toast_config(type) }.to_json
  end

  private

  def devise_alert_type(message)
    DEVISE_ALERT_TYPES.find { |key, _type| message.to_s == t(key) }&.last
  end
end
