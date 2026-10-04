module BillVision
  # Bad credentials, rejected input, unusable model output: retrying will not help.
  class PermanentError < Error; end
end
