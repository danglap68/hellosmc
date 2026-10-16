class MerchantDealer < ApplicationRecord
  has_paper_trail

  belongs_to :merchant
  belongs_to :dealer
  has_many :dealer_payment_qrs, dependent: :restrict_with_error

  before_validation :normalize_fields

  validates :tid_key, :tid_label, :ds_sheet_anchor, :ds_header, :rd_agent_label, presence: true
  validates :tid_key, uniqueness: { scope: :merchant_id }, if: :active?
  # "TK01": letters then digits (the digits let the matcher tell TK01 from TK010).
  # Unique across every agent row: a code names exactly one HKD + TID.
  validates :transfer_code, format: { with: RemitterTransfers::Codes::FORMAT }, allow_nil: true
  validates :transfer_code, uniqueness: { case_sensitive: false }, allow_nil: true
  validate :transfer_code_padding_unique

  scope :active, -> { where(active: true) }

  private

  def transfer_code_padding_unique
    return unless will_save_change_to_transfer_code? && transfer_code.present? && errors[:transfer_code].empty?

    key = RemitterTransfers::Codes.canonical(transfer_code)
    return unless key

    conflict = MerchantDealer.where.not(id: id).where.not(transfer_code: nil).pluck(:transfer_code)
      .find { |code| RemitterTransfers::Codes.canonical(code) == key }
    errors.add(:transfer_code, :padding_taken, code: conflict) if conflict
  end

  def normalize_fields
    self.tid_key = normalize_tid_key(tid_key)
    self.transfer_code = transfer_code.to_s.gsub(/\s+/, "").upcase.presence
    forget_names_of_previous_agent
    self.tid_label = tid_label.to_s.strip.presence || self.tid_key
    # Names on the Google Sheet, filled when left blank (the client does not
    # know them). The DS MB table name is never guessed from the merchant name
    # (a wrong guess sends every bill back to review): it is taken from
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
  # match the sheet is resolved by TID or sends the bill back to review with a
  # reason (Workbook::HelloSmcWriter), never to another agent's column.
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
