class ExcelExport < ApplicationRecord
  STATUSES = %w[pending processing completed failed].freeze
  LAYOUTS = %w[legacy ket_toan_phi_goc].freeze
  MAX_RANGE_DAYS = 93

  belongs_to :generated_by, class_name: "User", optional: true
  has_many :transactions, dependent: :nullify
  has_one_attached :file

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :layout, LAYOUTS.index_by(&:itself), validate: true, default: "legacy"

  validates :export_date, :end_date, presence: true
  validate :date_range_valid

  scope :recent_first, -> { order(created_at: :desc) }

  def date_range
    export_date..end_date
  end

  def filename
    dates = export_date == end_date ? export_date.strftime("%Y%m%d") : "#{export_date.strftime('%Y%m%d')}-#{end_date.strftime('%Y%m%d')}"
    return "smc-#{dates}.xlsx" unless ket_toan_phi_goc?

    stamp = (generated_at || Time.current).in_time_zone("Asia/Ho_Chi_Minh").strftime("%H%M%S")
    "smc-ket-toan-phi-goc-#{dates}-#{stamp}.xlsx"
  end

  private

  def date_range_valid
    return if export_date.blank? || end_date.blank?

    if end_date < export_date
      errors.add(:end_date, :before_start)
    elsif (end_date - export_date).to_i > MAX_RANGE_DAYS
      errors.add(:end_date, :range_too_long, count: MAX_RANGE_DAYS)
    end
  end
end
