class MerchantDealer < ApplicationRecord
  belongs_to :merchant
  belongs_to :dealer

  before_validation :normalize_fields

  validates :tid_key, :tid_label, :ds_sheet_anchor, :ds_header, :rd_agent_label, presence: true
  validates :tid_key, uniqueness: { scope: :merchant_id }, if: :active?

  scope :active, -> { where(active: true) }

  private

  def normalize_fields
    self.tid_key = Workbook::TidParser.normalize(tid_key) || tid_key.to_s.strip.downcase
    self.tid_label = tid_label.to_s.strip.presence
    self.ds_sheet_anchor = ds_sheet_anchor.to_s.strip.presence
    self.ds_header = ds_header.to_s.strip.presence
    self.rd_agent_label = rd_agent_label.to_s.strip.presence
  end
end
