module BillVision
  # Network failures, timeouts, rate limits, 5xx: safe to retry.
  class TransientError < Error; end
end
