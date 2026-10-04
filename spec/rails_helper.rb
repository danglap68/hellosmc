require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"
require "capybara/rspec"

Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.fixture_paths = [ Rails.root.join("spec/fixtures") ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include ActiveJob::TestHelper
  config.include ActiveSupport::Testing::TimeHelpers
  config.include Devise::Test::IntegrationHelpers, type: :request
  config.include Devise::Test::IntegrationHelpers, type: :system

  # Rails 8 loads routes lazily; Devise mappings need them.
  config.before(:suite) do
    Rails.application.reload_routes_unless_loaded
  end

  config.before(:each, type: :system) do
    driven_by :rack_test
  end

  # Fixture bills are dated 2026-10-04 (Vietnam time); freeze "now" just after.
  config.around do |example|
    travel_to(Time.find_zone!("Asia/Ho_Chi_Minh").local(2026, 10, 4, 18, 0, 0)) { example.run }
  end

  # Admin settings start from their defaults in every example.
  config.before do
    AppSetting.reset_cache!
    AppSecret.reset_cache!
  end

  # Deterministic secrets regardless of the developer's .env.
  config.around do |example|
    overrides = {
      "OPENAI_API_KEY" => "test-openai-key",
      "GEMINI_API_KEY" => nil,
      "TELEGRAM_BOT_TOKEN" => "123456:TEST-TOKEN",
      "TELEGRAM_WEBHOOK_SECRET" => nil,
      "APP_HOST" => nil,
      "R2_ACCESS_KEY_ID" => nil,
      "R2_SECRET_ACCESS_KEY" => nil,
      "R2_BUCKET" => nil,
      "R2_ENDPOINT" => nil
    }
    original = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
