class MerchantDealer < ApplicationRecord
  belongs_to :merchant
  belongs_to :dealer

  before_validation :normalize_fields

  validates :tid_key, :tid_label, :ds_sheet_anchor, :ds_header, :rd_agent_label, presence: true
  validates :tid_key, uniqueness: { scope: :merchant_id }, if: :active?

  scope :active, -> { where(active: true) }

  private

  def normalize_fields
    self.tid_key = normalize_tid_key(tid_key)
    self.tid_label = tid_label.to_s.strip.presence || self.tid_key
    # No fallback to the merchant name: the anchor must equal the HKD header in
    # the DS MB sheet, and a wrong guess silently sends bills to "Bill vô chủ".
    self.ds_sheet_anchor = ds_sheet_anchor.to_s.strip.presence
    self.ds_header = ds_header.to_s.strip.presence
    self.rd_agent_label = rd_agent_label.to_s.strip.presence
  end

  # "TID 127" / "tid127" / "127" => "tid127"
  def normalize_tid_key(value)
    raw = value.to_s.strip
    return "tid#{raw.to_i}" if raw.match?(/\A\d+\z/)

    Workbook::TidParser.normalize(raw) || raw.downcase
  end
end
