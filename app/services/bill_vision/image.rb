module BillVision
  Image = Data.define(:bytes, :mime_type) do
    def self.from_bill_image(bill_image)
      raise PermanentError, "Bill image #{bill_image.id} has no stored file" unless bill_image.image.attached?

      new(bytes: bill_image.image.download, mime_type: bill_image.image.blob.content_type)
    end

    def base64
      Base64.strict_encode64(bytes)
    end

    def data_url
      "data:#{mime_type};base64,#{base64}"
    end
  end
end
