# Fail fast with a clear message when R2 is selected but not configured
# (skipped during `assets:precompile`, which runs without secrets).
if Rails.configuration.active_storage.service.to_s == "cloudflare_r2" && ENV["SECRET_KEY_BASE_DUMMY"].blank?
  missing = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT].select { |key| ENV[key].blank? }
  if missing.any?
    raise "Cloudflare R2 storage requires #{missing.join(', ')} to be set"
  end
end
