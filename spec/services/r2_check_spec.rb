require "rails_helper"

RSpec.describe R2Check do
  let(:object_url) { %r{\Ahttps://account\.r2\.cloudflarestorage\.com/hellosmc-test/healthchecks/r2-check-[\w-]+\.txt} }
  let(:objects) { {} }

  before do
    ENV.update("R2_ACCESS_KEY_ID" => "test-key", "R2_SECRET_ACCESS_KEY" => "test-secret",
               "R2_BUCKET" => "hellosmc-test", "R2_ENDPOINT" => "https://account.r2.cloudflarestorage.com")
  end

  # An in-memory bucket behind the S3 API.
  def stub_bucket(get_body: nil)
    stub_request(:put, object_url).to_return { |request| objects[request.uri.path] = request.body; { status: 200 } }
    stub_request(:get, object_url).to_return do |request|
      objects.key?(request.uri.path) ? { status: 200, body: get_body || objects[request.uri.path] } : { status: 404 }
    end
    stub_request(:head, object_url).to_return { |request| { status: objects.key?(request.uri.path) ? 200 : 404 } }
    stub_request(:delete, object_url).to_return { |request| objects.delete(request.uri.path); { status: 204 } }
  end

  it "writes, reads, fetches through a presigned URL and deletes a test object" do
    stub_bucket

    result = described_class.call

    expect(result).to be_ok
    expect(result.steps.map(&:name)).to eq(described_class::STEPS)
    expect(objects).to be_empty
    expect(a_request(:get, object_url).with(query: hash_including("X-Amz-Signature"))).to have_been_made
  end

  it "stops at the failing step with a hint, e.g. a wrong secret key" do
    stub_request(:put, object_url).to_return(status: 403, body: <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match.</Message></Error>
    XML

    result = described_class.call

    expect(result).not_to be_ok
    expect(result.failure.name).to eq(:upload)
    expect(result.failure.hint).to eq(:secret_key)
    expect(result.steps.map(&:name)).to eq(%i[configuration upload])
  end

  it "removes the test object when a later step fails" do
    stub_bucket(get_body: "something else")

    result = described_class.call

    expect(result.failure.name).to eq(:download)
    expect(objects).to be_empty
  end

  it "reports missing variables without calling R2" do
    ENV.delete("R2_BUCKET")

    result = described_class.call

    expect(result.failure.name).to eq(:configuration)
    expect(result.failure.hint).to eq(:missing)
    expect(result.failure.error.message).to eq("R2_BUCKET")
  end
end
