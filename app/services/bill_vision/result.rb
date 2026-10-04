module BillVision
  # data: the standardized extraction hash (see BillVision::Prompt::SCHEMA)
  # raw:  the provider response, kept verbatim for audit and debugging
  Result = Data.define(:provider, :model, :data, :raw)
end
