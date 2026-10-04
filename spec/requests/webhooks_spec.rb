require "rails_helper"

RSpec.describe "Telegram webhook" do
  let(:update) { telegram_fixture("photo_update") }

  def deliver(body, headers = {})
    post "/webhooks/telegram", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  it "enqueues the update and returns immediately" do
    deliver(update)
    expect(response).to have_http_status(:ok)
    expect(ProcessTelegramUpdateJob).to have_been_enqueued.with(update)
    expect(TelegramMessage.count).to eq(0)
  end

  context "with a configured secret" do
    before { ENV["TELEGRAM_WEBHOOK_SECRET"] = "s3cret" }

    it "accepts the matching secret header" do
      deliver(update, "X-Telegram-Bot-Api-Secret-Token" => "s3cret")
      expect(response).to have_http_status(:ok)
    end

    it "rejects a wrong or missing secret" do
      deliver(update, "X-Telegram-Bot-Api-Secret-Token" => "nope")
      expect(response).to have_http_status(:unauthorized)
      deliver(update)
      expect(response).to have_http_status(:unauthorized)
      expect(ProcessTelegramUpdateJob).not_to have_been_enqueued
    end
  end

  it "rejects malformed JSON" do
    post "/webhooks/telegram", params: "{not json", headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:bad_request)
  end
end

RSpec.describe "Health check" do
  it "reports database and redis status" do
    allow(Sidekiq).to receive(:redis).and_return("PONG")
    get "/health"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "ok", "checks" => { "database" => "ok", "redis" => "ok" })
  end

  it "reports degraded when redis is down" do
    allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError)
    get "/health"
    expect(response).to have_http_status(:service_unavailable)
  end
end
