require "rails_helper"

RSpec.describe AppSecret do
  it "encrypts values at rest and reads them back" do
    described_class.set!("telegram_bot_token", "123:SECRET")

    expect(described_class.get("telegram_bot_token")).to eq("123:SECRET")
    expect(described_class.connection.select_value("SELECT value FROM app_secrets")).not_to include("123:SECRET")
  end

  it "only accepts known keys" do
    expect { described_class.get("openai_api_key") }.to raise_error(ArgumentError)
    expect { described_class.set!("openai_api_key", "x") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "picks up a changed value immediately in the same process" do
    described_class.set!("telegram_webhook_secret", "one")
    expect(described_class.get("telegram_webhook_secret")).to eq("one")

    described_class.set!("telegram_webhook_secret", "two")
    expect(described_class.get("telegram_webhook_secret")).to eq("two")
  end
end
