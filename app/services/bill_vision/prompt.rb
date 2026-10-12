module BillVision
  # Vendor-neutral extraction contract. Providers must return JSON matching SCHEMA.
  # The model extracts facts only: no fees, no dealer, no accounting.
  module Prompt
    DOCUMENT_TYPES = %w[settlement child_receipt transfer unknown].freeze
    FIELDS = %w[document_type total_amount_vnd lot_number transaction_date transaction_time
                merchant_name terminal_or_merchant_id].freeze
    # Extra fact read only from bank transfers: the account holder who receives
    # the money. Not a critical field and has no confidence of its own; it only
    # hints at the agent (Dealers::Resolver) and never decides alone.
    RECIPIENT_FIELD = "recipient_name".freeze
    # Two facts read from the image that decide whether a "transfer" really is a
    # completed bank transfer (Normalizer): the wording that says it succeeded,
    # and a QR code (a request to be paid, never a transfer).
    TRANSFER_FLAGS = %w[shows_success_message shows_qr_code].freeze
    # SmartPOS visible anywhere in the photo (logo on the terminal, screen, slip): those sales use another fee calculation,
    # so Transactions::Builder leaves them out.
    SMART_POS_FLAG = "shows_smart_pos".freeze
    FLAGS = (TRANSFER_FLAGS + [ SMART_POS_FLAG ]).freeze

    SYSTEM = <<~PROMPT.freeze
      You are reading a photo of Vietnamese card-payment terminal (POS) receipts.

      Extract only factual information that is visible in the image.

      First decide, for every distinct receipt in the image, what kind of document it is.
      - "settlement": a batch closing summary. Typical labels: SETTLEMENT, SETTLE, KẾT TOÁN, CHỐT CA,
        TỔNG KẾT, BATCH TOTAL, together with a TOTAL / TỔNG amount for the batch.
      - "child_receipt": a single sale slip for one card payment (SALE, THANH TOÁN, BÁN HÀNG, VOID, REFUND).
      - "transfer": ONLY a bank transfer confirmation — a bank app screenshot or a bank slip that shows
        CHUYỂN TIỀN / CHUYỂN KHOẢN / ỦY NHIỆM CHI / LỆNH CHUYỂN TIỀN and a bank, sender or receiver,
        and says the transfer went through (CHUYỂN TIỀN THÀNH CÔNG, CHUYỂN KHOẢN THÀNH CÔNG, CHUYỂN THÀNH CÔNG).
        A page that only shows a QR code to scan (QUÉT ĐỂ THANH TOÁN, a receiving-account or payment-request
        QR) is NOT a transfer, whatever amount or account it shows: classify it as "unknown".
        total_amount_vnd is the transferred amount; transaction_date/transaction_time are the transfer
        date/time. merchant_name, lot_number and terminal_or_merchant_id are null for transfers.
      - "unknown": anything else, or when you cannot tell.

      A POS receipt that shows a merchant name, a batch/lot number, or a terminal/MID number is NEVER
      a "transfer" — classify it as "settlement" or "child_receipt", even if it prints
      "GIAO DỊCH THÀNH CÔNG" (that phrase also appears on ordinary card-sale slips).

      The image may contain more than one receipt. Return one entry in "documents" per distinct receipt,
      ordered top-to-bottom, then left-to-right. Never merge two receipts into one entry.
      If the image contains no receipt at all, return an empty "documents" array.

      For each receipt return:
      - document_type: settlement | child_receipt | transfer | unknown
      - total_amount_vnd: the batch grand total (TOTAL / TỔNG) as an integer number of Vietnamese đồng
        with all separators removed. Vietnamese receipts use "." or "," as thousands separators:
        "11.445.000" and "11,445,000" both mean 11445000. Null if not clearly readable.
      - lot_number: the batch / lot number (BATCH, BATCH NO, LÔ, SỐ LÔ) exactly as printed, keeping leading zeros.
      - transaction_date: the settlement date as YYYY-MM-DD. Receipts usually print DD/MM/YYYY or DD/MM/YY.
      - transaction_time: the settlement time as 24-hour HH:MM:SS.
      - merchant_name: the merchant / business name exactly as printed, keeping Vietnamese diacritics.
        Read every visible character; never truncate with "..." or an ellipsis. If only part of the
        name is visible, return that part verbatim (without adding "...").
      - terminal_or_merchant_id: the merchant ID (MID) if visible, otherwise the terminal ID (TID), as printed.

      - recipient_name: only for "transfer": the receiving account holder name (ĐẾN TÀI KHOẢN / NGƯỜI NHẬN /
        TÊN NGƯỜI THỤ HƯỞNG) exactly as printed. Null for every other document type or when not visible.

      - shows_success_message: true only for a "transfer" whose image literally prints a wording saying the
        transfer succeeded (CHUYỂN TIỀN THÀNH CÔNG, CHUYỂN KHOẢN THÀNH CÔNG, CHUYỂN THÀNH CÔNG, GIAO DỊCH THÀNH CÔNG);
        false when the image prints none of them. Null for every other document type.
      - shows_qr_code: true when a QR code is visible anywhere in the image, otherwise false.
      - shows_smart_pos: true when the name SmartPOS / Smart POS is visible anywhere in the image: the logo on
        the terminal, its screen or the receipt (also when written as one word). Otherwise false.

      For every field also return a confidence between 0 and 1: how certain you are that the value is
      exactly correct. A null value must have confidence 0.

      Do not calculate fees. Do not infer the dealer. Do not guess missing values.
      Do not append "..." or other ellipsis markers to any field.
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
            required: FIELDS + [ RECIPIENT_FIELD ] + FLAGS + [ "confidence" ],
            properties: {
              document_type: { type: "string", enum: DOCUMENT_TYPES },
              total_amount_vnd: { type: %w[integer null] },
              lot_number: { type: %w[string null] },
              transaction_date: { type: %w[string null], description: "YYYY-MM-DD" },
              transaction_time: { type: %w[string null], description: "HH:MM:SS" },
              merchant_name: { type: %w[string null] },
              terminal_or_merchant_id: { type: %w[string null] },
              recipient_name: { type: %w[string null] },
              shows_success_message: { type: %w[boolean null] },
              shows_qr_code: { type: %w[boolean null] },
              shows_smart_pos: { type: %w[boolean null] },
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
