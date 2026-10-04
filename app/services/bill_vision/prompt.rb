module BillVision
  # Vendor-neutral extraction contract. Providers must return JSON matching SCHEMA.
  # The model extracts facts only: no fees, no dealer, no accounting.
  module Prompt
    DOCUMENT_TYPES = %w[settlement child_receipt unknown].freeze
    FIELDS = %w[document_type total_amount_vnd lot_number transaction_date transaction_time
                merchant_name terminal_or_merchant_id].freeze

    SYSTEM = <<~PROMPT.freeze
      You are reading a photo of Vietnamese card-payment terminal (POS) receipts.

      Extract only factual information that is visible in the image.

      First decide, for every distinct receipt in the image, whether it is a settlement/closing receipt.
      - "settlement": a batch closing summary. Typical labels: SETTLEMENT, SETTLE, KẾT TOÁN, CHỐT CA,
        TỔNG KẾT, BATCH TOTAL, together with a TOTAL / TỔNG amount for the batch.
      - "child_receipt": a single sale slip for one card payment (SALE, THANH TOÁN, BÁN HÀNG, VOID, REFUND).
      - "unknown": anything else, or when you cannot tell.

      The image may contain more than one receipt. Return one entry in "documents" per distinct receipt,
      ordered top-to-bottom, then left-to-right. Never merge two receipts into one entry.
      If the image contains no receipt at all, return an empty "documents" array.

      For each receipt return:
      - document_type: settlement | child_receipt | unknown
      - total_amount_vnd: the batch grand total (TOTAL / TỔNG) as an integer number of Vietnamese đồng
        with all separators removed. Vietnamese receipts use "." or "," as thousands separators:
        "11.445.000" and "11,445,000" both mean 11445000. Null if not clearly readable.
      - lot_number: the batch / lot number (BATCH, BATCH NO, LÔ, SỐ LÔ) exactly as printed, keeping leading zeros.
      - transaction_date: the settlement date as YYYY-MM-DD. Receipts usually print DD/MM/YYYY or DD/MM/YY.
      - transaction_time: the settlement time as 24-hour HH:MM:SS.
      - merchant_name: the merchant / business name exactly as printed, keeping Vietnamese diacritics.
      - terminal_or_merchant_id: the merchant ID (MID) if visible, otherwise the terminal ID (TID), as printed.

      For every field also return a confidence between 0 and 1: how certain you are that the value is
      exactly correct. A null value must have confidence 0.

      Do not calculate fees. Do not infer the dealer. Do not guess missing values.
      If you are uncertain about a value, return null.
      Use "notes" only for short remarks about image quality or obstructions, otherwise null.
    PROMPT

    USER = "Extract the receipt data from this image as JSON.".freeze

    SCHEMA = {
      type: "object",
      additionalProperties: false,
      required: %w[documents notes],
      properties: {
        documents: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: FIELDS + [ "confidence" ],
            properties: {
              document_type: { type: "string", enum: DOCUMENT_TYPES },
              total_amount_vnd: { type: %w[integer null] },
              lot_number: { type: %w[string null] },
              transaction_date: { type: %w[string null], description: "YYYY-MM-DD" },
              transaction_time: { type: %w[string null], description: "HH:MM:SS" },
              merchant_name: { type: %w[string null] },
              terminal_or_merchant_id: { type: %w[string null] },
              confidence: {
                type: "object",
                additionalProperties: false,
                required: FIELDS,
                properties: FIELDS.index_with { { type: "number" } }
              }
            }
          }
        },
        notes: { type: %w[string null] }
      }
    }.freeze
  end
end
