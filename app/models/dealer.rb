class Dealer < ApplicationRecord
  has_paper_trail

  belongs_to :default_card_type, class_name: "CardType", optional: true

  has_many :merchant_dealers, dependent: :restrict_with_error
  has_many :assigned_merchants, through: :merchant_dealers, source: :merchant
  has_many :fee_rules, dependent: :restrict_with_error
  has_many :transactions, dependent: :restrict_with_error
  has_many :dealer_payment_qrs, dependent: :restrict_with_error

  before_validation { self.code = code.to_s.strip.upcase.presence }
  before_validation do
    self.bank_bin = bank_bin.to_s.strip.presence
    self.bank_account_number = bank_account_number.to_s.gsub(/\s+/, "").presence
    self.bank_account_name = bank_account_name.to_s.strip.presence
  end

  validates :name, presence: true, length: { maximum: 200 }
  validates :code, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 50 }
  validates :bank_bin, inclusion: { in: ->(_) { PaymentQrs::Banks.all.map { |bank| bank.fetch("bin") } } }, allow_nil: true
  validates :bank_account_number, format: { with: /\A[a-zA-Z0-9]{1,19}\z/ }, allow_nil: true
  validates :bank_account_name, length: { maximum: 100 }, allow_nil: true
  with_options if: -> { auto_payment_qr? || [ bank_bin, bank_account_number, bank_account_name ].any?(&:present?) } do
    validates :bank_bin, :bank_account_number, :bank_account_name, presence: true
  end

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }

  def display_name
    name
  end
end
