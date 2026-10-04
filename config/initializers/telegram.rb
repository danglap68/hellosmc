Telegram::Bot.configure do |config|
  # Long polling holds the connection open; keep the HTTP timeout above the poll timeout.
  config.connection_timeout = 40
  config.connection_open_timeout = 10
end
