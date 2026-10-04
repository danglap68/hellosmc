require "aws-sdk-s3"

# Verifies the Cloudflare R2 credentials end to end with a throwaway object
# under healthchecks/: write, read back, fetch through a presigned URL (how bill
# images and exports are served), delete. Works whichever storage service is
# active, so R2 can be checked before switching to it.
class R2Check
  STEPS = %i[configuration upload download presigned_url delete].freeze

  class MissingConfiguration < StandardError; end
  class Mismatch < StandardError; end

  HINTS = {
    "R2Check::MissingConfiguration" => :missing,
    "Aws::S3::Errors::InvalidAccessKeyId" => :access_key,
    "Aws::S3::Errors::SignatureDoesNotMatch" => :secret_key,
    "Aws::S3::Errors::NoSuchBucket" => :bucket,
    "Aws::S3::Errors::AccessDenied" => :permission,
    "Aws::S3::Errors::Forbidden" => :permission,
    "Seahorse::Client::NetworkingError" => :endpoint
  }.freeze

  Step = Data.define(:name, :error) do
    def ok? = error.nil?
    def hint = error && HINTS[error.class.name]
  end

  Result = Data.define(:steps, :duration_ms) do
    def ok? = steps.size == STEPS.size && steps.all?(&:ok?)
    def failure = steps.find { |step| !step.ok? }
  end

  def self.call = new.call

  def initialize
    @key = "healthchecks/r2-check-#{SecureRandom.uuid}.txt"
    @payload = "SMC R2 check #{Time.current.utc.iso8601}"
    @steps = []
  end

  def call
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run(:configuration) { check_configuration } &&
      run(:upload) { upload } &&
      run(:download) { download } &&
      run(:presigned_url) { fetch_presigned_url } &&
      run(:delete) { delete }

    result = Result.new(steps: @steps, duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
    StructuredLog.info("r2.checked", ok: result.ok?, failed_step: result.failure&.name,
                                     error_class: result.failure&.error&.class&.name, duration_ms: result.duration_ms)
    result
  ensure
    cleanup
  end

  private

  def run(name)
    yield
    @steps << Step.new(name: name, error: nil)
    true
  rescue StandardError => e
    @steps << Step.new(name: name, error: e)
    false
  end

  def check_configuration
    missing = AppConfig.r2_missing_env
    raise MissingConfiguration, missing.join(", ") if missing.any?

    service
  end

  def upload
    service.upload(@key, StringIO.new(@payload))
    @uploaded = true
  end

  def download
    raise Mismatch, "downloaded content differs" unless service.download(@key).b == @payload.b
  end

  def fetch_presigned_url
    url = service.url(@key, expires_in: 1.minute, filename: ActiveStorage::Filename.new("r2-check.txt"),
                            disposition: :inline, content_type: "text/plain")
    response = Faraday.new(request: { open_timeout: 5, timeout: 10 }).get(url)
    raise Mismatch, "presigned URL returned HTTP #{response.status}" unless response.status == 200
    raise Mismatch, "presigned URL returned different content" unless response.body.b == @payload.b
  end

  def delete
    service.delete(@key)
    @uploaded = false
    raise Mismatch, "object still exists after delete" if service.exist?(@key)
  end

  def cleanup
    service.delete(@key) if @uploaded
  rescue StandardError
    nil
  end

  # The cloudflare_r2 service from config/storage.yml, failing fast instead of
  # the SDK's retries and long timeouts.
  def service
    @service ||= begin
      configurations = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
      configurations["cloudflare_r2"] = configurations.fetch("cloudflare_r2")
        .merge("retry_limit" => 0, "http_open_timeout" => 5, "http_read_timeout" => 10)
      ActiveStorage::Service.configure(:cloudflare_r2, configurations)
    end
  end
end
