module Admin
  # Serves private bill images to signed-in users only. On R2/S3 this
  # redirects to a presigned URL valid for a few minutes; on disk storage
  # (development/test) the bytes are streamed.
  class BillImagesController < BaseController
    permission :bill_images

    def show
      bill_image = BillImage.find(params[:id])
      bill_image = bill_image.duplicate_of if !bill_image.image.attached? && bill_image.duplicate_of
      return head :not_found unless bill_image&.image&.attached?

      blob = bill_image.image.blob
      if blob.service.is_a?(ActiveStorage::Service::DiskService)
        response.headers["Cache-Control"] = "private, max-age=300"
        send_data blob.download, type: blob.content_type, disposition: "inline", filename: blob.filename.to_s
      else
        redirect_to blob.url(expires_in: 5.minutes, disposition: "inline"), allow_other_host: true
      end
    end
  end
end
