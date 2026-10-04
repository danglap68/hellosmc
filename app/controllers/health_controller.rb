# Liveness + dependency check for load balancers and uptime monitors.
class HealthController < ActionController::API
  def show
    checks = { database: database_ok?, redis: redis_ok? }
    status = checks.values.all? ? :ok : :service_unavailable
    render json: { status: status == :ok ? "ok" : "degraded", checks: checks.transform_values { |ok| ok ? "ok" : "fail" } },
           status: status
  end

  private

  def database_ok?
    ActiveRecord::Base.connection.select_value("SELECT 1") == 1
  rescue StandardError
    false
  end

  def redis_ok?
    Sidekiq.redis { |connection| connection.call("PING") } == "PONG"
  rescue StandardError
    false
  end
end
