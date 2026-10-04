class ApplicationJob < ActiveJob::Base
  # Records may disappear between enqueue and perform; nothing to retry then.
  discard_on ActiveJob::DeserializationError
  discard_on ActiveRecord::RecordNotFound

  around_perform do |job, block|
    StructuredLog.info("job.started", job_class: job.class.name, job_id: job.job_id, attempt: job.executions)
    block.call
  end
end
