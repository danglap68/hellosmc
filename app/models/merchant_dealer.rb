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
    forget_names_of_previous_agent
    self.tid_label = tid_label.to_s.strip.presence || self.tid_key
    # Names on the Google Sheet, filled when left blank (the client does not
    # know them). The DS MB table name is never guessed from the merchant name
    # (a wrong guess silently sends bills to "Bill vô chủ"): it is taken from
    # another agent row of the same merchant, which already matches the sheet.
    # The column header "Chương (tid1)" and the thu chi label "Chương" follow
    # the sheet's convention (matching ignores spaces and accents).
    self.ds_sheet_anchor = ds_sheet_anchor.to_s.strip.presence || sibling_anchor
    self.ds_header = ds_header.to_s.strip.presence || (dealer && tid_key.present? ? "#{dealer.name} (#{tid_key})" : nil)
    self.rd_agent_label = rd_agent_label.to_s.strip.presence || dealer&.name
  end

  # The sheet names are hidden under "Nâng cao", so a client who switches the
  # agent or the TID of a row would not see them go stale: the row would keep
  # writing to the previous agent's column. They are rebuilt for the new agent
  # unless they were edited in the same change. A rebuilt name that does not
  # match the sheet sends the bill to "Bill vô chủ" with a reason (visible),
  # never to another agent's column.
  def forget_names_of_previous_agent
    return unless persisted?

    agent_changed = dealer_id_changed?
    tid_changed = tid_key_changed?
    return unless agent_changed || tid_changed

    self.ds_header = nil unless ds_header_changed?
    self.rd_agent_label = nil if agent_changed && !rd_agent_label_changed?
    self.tid_label = nil if tid_changed && !tid_label_changed?
  end

  def sibling_anchor
    return unless merchant

    merchant.merchant_dealers.reject { |link| link.equal?(self) }.filter_map { |link| link.ds_sheet_anchor.presence }.first
  end

  # "TID 127" / "tid127" / "127" => "tid127"
  def normalize_tid_key(value)
    raw = value.to_s.strip
    return "tid#{raw.to_i}" if raw.match?(/\A\d+\z/)

    Workbook::TidParser.normalize(raw) || raw.downcase
  end
end
