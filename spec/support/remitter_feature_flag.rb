# The remitter feature flag defaults to off in production. Most specs exercise
# the full flow, so it is on unless an example turns it off with
# `allow(AppConfig).to receive(:remitter_features_enabled?).and_return(false)`.
RSpec.configure do |config|
  config.before do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true)
  end
end
