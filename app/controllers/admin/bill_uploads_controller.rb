module Admin
  # Manual upload of a settlement image (testing OCR, or bills received
  # outside Telegram). Goes through the exact same pipeline.
  class BillUploadsController < BaseController
    permission :bill_uploads

    def new
      @upload = BillUploadForm.new
    end

    def create
      @upload = BillUploadForm.new(upload_params.merge(user: current_user))
      if (bill_image = @upload.save)
        AnalyzeBillImageJob.perform_later(bill_image.id)
        redirect_to admin_reviews_path, notice: t("bill_uploads.flash.queued")
      else
        render :new, status: :unprocessable_content
      end
    end

    private

    def upload_params
      params.fetch(:bill_upload_form, {}).permit(:image, :dealer_id, :card_type_key, :note)
    end
  end
end
