module Admin
  class ExcelExportsController < BaseController
    permission :excel_exports

    before_action :set_export, only: %i[show download]

    def index
      @pagy, @excel_exports = pagy(ExcelExport.includes(:generated_by).recent_first)
    end

    def show; end

    def new
      today = Time.zone.today
      @excel_export = ExcelExport.new(export_date: today, end_date: today)
      @preview_count = preview_count(@excel_export)
    end

    def create
      @excel_export = ExcelExport.new(export_params.merge(generated_by: current_user, status: "pending"))
      if @excel_export.save
        GenerateDailyExcelJob.perform_later(@excel_export.id)
        redirect_to admin_excel_export_path(@excel_export), notice: t("excel_exports.flash.queued")
      else
        @preview_count = 0
        render :new, status: :unprocessable_content
      end
    end

    def download
      return redirect_to(admin_excel_export_path(@excel_export), alert: t("excel_exports.flash.not_ready")) unless @excel_export.file.attached?

      AuditLogger.log!(actor: current_user, action: "export.downloaded", auditable: @excel_export)
      blob = @excel_export.file.blob
      if blob.service.is_a?(ActiveStorage::Service::DiskService)
        send_data blob.download, filename: @excel_export.filename, type: blob.content_type, disposition: "attachment"
      else
        redirect_to blob.url(expires_in: 5.minutes, disposition: "attachment", filename: @excel_export.filename),
                    allow_other_host: true
      end
    end

    private

    def set_export
      @excel_export = ExcelExport.find(params[:id])
    end

    def export_params
      params.require(:excel_export).permit(:export_date, :end_date)
    end

    def preview_count(export)
      from = Time.zone.local(export.export_date.year, export.export_date.month, export.export_date.day)
      Transaction.where(status: Exports::LegacyLayout::EXPORTABLE_STATUSES,
                        transaction_at: from..from.end_of_day).count
    end
  end
end
