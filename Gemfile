source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Redis: Sidekiq backend, Action Cable adapter, health checks
gem "redis", ">= 4.0.1"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Background jobs
gem "sidekiq", "~> 8.0"

# Authentication
gem "devise", "~> 4.9"

# Vietnamese locale data for Rails and Devise
gem "rails-i18n", "~> 8.0"
gem "devise-i18n"

# Telegram Bot API client
gem "telegram-bot-ruby", "~> 2.4", require: "telegram/bot"

# Cloudflare R2 (S3-compatible) for Active Storage
gem "aws-sdk-s3", require: false

# Excel export
gem "caxlsx", "~> 4.1"

# HTTP client for vision providers and Telegram file downloads
gem "faraday", "~> 2.12"

# Image dimensions without native image libraries
gem "fastimage", "~> 2.4"

# Pagination
gem "pagy", "~> 9.3"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  gem "dotenv-rails"
  gem "rspec-rails", "~> 8.0"
  gem "factory_bot_rails"
  gem "faker"
end

group :test do
  gem "webmock"
  gem "shoulda-matchers", "~> 6.4"
  gem "capybara"
  gem "csv"
  gem "roo", "~> 2.10", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Open sent emails in the browser instead of delivering them; inbox at /letter_opener
  gem "letter_opener_web", "~> 3.0"
end
