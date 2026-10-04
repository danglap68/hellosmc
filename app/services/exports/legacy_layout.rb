module Exports
  # Explicit mapping from the clean domain model to the customer's current
  # accounting workbook. Headers are kept exactly as in the legacy file even
  # where they are semantically odd (e.g. "Tên Đại lý" holds the HKD name and
  # the last column has no header). Change the mapping here, not the schema.
  module LegacyLayout
    STATUS_LABELS = {
      "approved" => "Thành công",
      "exported" => "Thành công",
      "hold" => "bill hold"
    }.freeze
    EXPORTABLE_STATUSES = STATUS_LABELS.keys.freeze
    SUCCESS_LABEL = "Thành công".freeze

    Column = Data.define(:header, :type, :value)

    COLUMNS = [
      Column.new(header: "Tên Đại lý", type: :string, value: ->(t) { t.merchant&.name }),
      Column.new(header: "Số tiền sau khi trừ phí gốc", type: :integer, value: ->(t) { t.amount_after_base_fee_vnd }),
      Column.new(header: "Số tiền giao dịch", type: :integer, value: ->(t) { t.transaction_amount_vnd }),
      Column.new(header: "Phí gốc", type: :rate, value: ->(t) { t.applied_base_fee_rate }),
      Column.new(header: "Ngày giao dịch", type: :datetime, value: ->(t) { t.transaction_at&.in_time_zone }),
      Column.new(header: "Trạng thái", type: :string, value: ->(t) { STATUS_LABELS[t.status] }),
      Column.new(header: "", type: :string, value: ->(t) { t.dealer&.name })
    ].freeze

    module_function

    def headers
      COLUMNS.map(&:header)
    end

    def row(transaction)
      COLUMNS.map { |column| column.value.call(transaction) }
    end
  end
end
