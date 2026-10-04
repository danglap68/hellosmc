module Dashboard
  # Figures for the admin dashboard, for one business day (Vietnam time).
  class Stats
    def initialize(date: Time.zone.today)
      @date = date
      @day = Time.zone.local(date.year, date.month, date.day).all_day
    end

    attr_reader :date

    def bills_today
      BillImage.where(created_at: @day).count
    end

    def processed_today
      Transaction.where(created_at: @day).where.not(status: %w[pending processing]).count
    end

    def needs_review
      Transaction.where(status: "needs_review").count
    end

    def hold
      Transaction.where(status: "hold").count
    end

    def failed
      Transaction.where(status: "failed").count + BillImage.where(ocr_status: "failed").where.missing(:transactions).count
    end

    def total_amount_today
      Transaction.where(transaction_at: @day).where.not(status: %w[rejected failed]).sum(:transaction_amount_vnd)
    end

    def total_approved_amount_today
      Transaction.where(transaction_at: @day, status: %w[approved exported]).sum(:transaction_amount_vnd)
    end

    def latest_transactions(limit = 8)
      Transaction.includes(:dealer, :merchant, :card_type).recent_first.limit(limit)
    end

    def latest_review_items(limit = 6)
      Transaction.review_queue.includes(:dealer, :merchant).order(:created_at).limit(limit)
    end

    # Approved/exported totals per dealer over the last 30 days.
    def top_dealers(limit = 5)
      Transaction.where(status: %w[approved exported], transaction_at: 30.days.ago..)
        .joins(:dealer)
        .group("dealers.id", "dealers.name")
        .order(Arel.sql("SUM(transactions.transaction_amount_vnd) DESC"))
        .limit(limit)
        .pluck("dealers.id", "dealers.name", Arel.sql("COUNT(*)"), Arel.sql("SUM(transactions.transaction_amount_vnd)"))
    end
  end
end
