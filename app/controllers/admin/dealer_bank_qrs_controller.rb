module Admin
  class DealerBankQrsController < BaseController
    permission :dealers
    # Nothing is persisted until the dealer form is explicitly saved.
    def create
      response.headers["Cache-Control"] = "no-store"
      fields = PaymentQrs::RecipientParser.call(params[:qr_payload])
      if fields["bank_account_name"].blank? && params[:image].present?
        fields["bank_account_name"] = read_name(fields)
        fields["name_source"] = "image" if fields["bank_account_name"].present?
      end
      fields["message"] ||= if fields["bank_account_name"].present?
        "Đã điền thông tin từ ảnh QR. Kiểm tra ngân hàng, số tài khoản và tên người nhận rồi bấm Lưu."
      else
        "Đã đọc ngân hàng và số tài khoản. QR / ảnh chưa có tên người nhận đọc được; hãy bổ sung tên trước khi lưu."
      end
      render json: fields
    rescue PaymentQrs::Error => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def read_name(fields)
      upload = params[:image]
      raise PaymentQrs::Error, "Ảnh QR không hợp lệ." unless upload.respond_to?(:read) && upload.respond_to?(:size)
      raise PaymentQrs::Error, "Ảnh QR tối đa 4 MB." if upload.size > 4.megabytes

      bytes = upload.read(4.megabytes + 1).to_s.b
      mime = Marcel::MimeType.for(StringIO.new(bytes))
      dimensions = FastImage.size(StringIO.new(bytes))
      unless mime.in?(%w[image/png image/jpeg image/webp]) && dimensions&.all?(&:positive?) && dimensions.inject(:*) <= 24_000_000
        raise PaymentQrs::Error, "Dùng ảnh QR PNG, JPG hoặc WebP rõ nét, tối đa 24 megapixel."
      end
      PaymentQrs::RecipientNameReader.call(image: BillVision::Image.new(bytes: bytes, mime_type: mime),
                                          account_number: fields.fetch("bank_account_number"))
    rescue BillVision::Error
      StructuredLog.warn("dealer.bank_qr_name_unavailable", user_id: current_user.id)
      fields["message"] = "Đã đọc ngân hàng và số tài khoản. Chưa đọc được tên trên ảnh lúc này; hãy bổ sung tên trước khi lưu."
      nil
    end
  end
end
