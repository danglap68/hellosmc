class GenerateDailyExcelJob < ApplicationJob
  queue_as :exports

  # Generation failures are recorded on the export; a human regenerates.
  discard_on StandardError do |job, error|
    StructuredLog.error("export.job_failed", job_id: job.job_id, excel_export_id: job.arguments.first,
                                             error_class: error.class.name)
  end

  # With an id, generates that export. Without, creates and generates the
  # export for yesterday (for a scheduled daily run via cron/rake).
  def perform(excel_export_id = nil)
    export = excel_export_id ? ExcelExport.find(excel_export_id) : create_yesterday_export
    return if export.completed?

    Exports::ExcelGenerator.call(excel_export: export)
  end

  private

  def create_yesterday_export
    date = Time.zone.yesterday
    ExcelExport.create!(export_date: date, end_date: date, metadata: { "trigger" => "scheduled" })
  end
end
