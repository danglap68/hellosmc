require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Hellosmc
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Business times are rendered in Vietnam time; the database stores UTC.
    config.time_zone = "Asia/Ho_Chi_Minh"
    config.active_record.default_timezone = :utc

    # Code is English; every user-facing string is Vietnamese via I18n.
    config.i18n.default_locale = :vi
    config.i18n.available_locales = [ :vi ]
    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.yml")]
    config.i18n.raise_on_missing_translations = false

    config.active_job.queue_adapter = :sidekiq

    # Outgoing email server, e.g. Resend: smtp.resend.com, user "resend", password = API key.
    # Production always sends through it; development only when SMTP_ADDRESS is set.
    config.action_mailer.smtp_settings = {
      address: ENV["SMTP_ADDRESS"],
      port: ENV.fetch("SMTP_PORT", 587).to_i,
      user_name: ENV["SMTP_USERNAME"],
      password: ENV["SMTP_PASSWORD"],
      authentication: :plain,
      enable_starttls_auto: true
    }

    # Bill images are private: no public Active Storage routes. Images are
    # served through authenticated admin endpoints (see Admin::BillImagesController).
    config.active_storage.draw_routes = false
    config.active_storage.analyzers = []
    config.active_storage.variant_processor = :disabled
    config.active_storage.service_urls_expire_in = 5.minutes

    config.generators do |g|
      g.test_framework :rspec
      g.system_tests = nil
      g.helper false
      g.assets false
    end
  end
end
