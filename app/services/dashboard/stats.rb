module Dashboard
  # Figures for the admin dashboard, for one business day (Vietnam time).
  class Stats
    PERIODS = %w[7d 30d 90d 12m].freeze

    def initialize(date: Time.zone.today, period: "30d")
      @date = date
      @day = Time.zone.local(date.year, date.month, date.day).all_day
      @period_key = PERIODS.include?(period.to_s) ? period.to_s : "30d"
    end

    attr_reader :date, :period_key

    def bills_today
      BillImage.where(created_at: @day).count
    end

    def processed_today
      Transaction.where(created_at: @day).where.not(status: %w[pending processing excluded]).count
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
      Transaction.where(transaction_at: @day).where.not(status: %w[rejected failed excluded]).sum(:transaction_amount_vnd)
    end

    def total_approved_amount_today
      Transaction.where(transaction_at: @day, status: "approved").sum(:transaction_amount_vnd)
    end

    def latest_transactions(limit = 8)
      Transaction.where.not(status: "excluded").includes(:dealer, :merchant, :card_type).recent_first.limit(limit)
    end

    def latest_review_items(limit = 6)
      Transaction.review_queue.includes(:dealer, :merchant).order(:created_at).limit(limit)
    end

    # Approved totals per dealer over the last 30 days.
    def top_dealers(limit = 5)
      Transaction.where(status: "approved", transaction_at: 30.days.ago..)
        .joins(:dealer)
        .group("dealers.id", "dealers.name")
        .order(Arel.sql("SUM(transactions.transaction_amount_vnd) DESC"))
        .limit(limit)
        .pluck("dealers.id", "dealers.name", Arel.sql("COUNT(*)"), Arel.sql("SUM(transactions.transaction_amount_vnd)"))
    end

    def window_start
      @date - 29
    end

    def period_start
      case @period_key
      when "7d" then @date - 6
      when "90d" then @date - 89
      when "12m" then (@date << 11).beginning_of_month
      else @date - 29
      end
    end

    def period_end
      @date
    end

    def previous_end
      period_start - 1
    end

    def previous_start
      if @period_key == "12m"
        (period_start << 12)
      else
        length = (period_end - period_start).to_i
        previous_end - length
      end
    end

    # Live queues, not limited to the selected period.
    def unmatched_albums
      BillAlbum.where(reconciliation_status: %w[mismatched multiple_transfers missing_bills no_transfer]).count
    end

    def transfers_needing_review
      RemitterTransfer.where(status: "needs_review").count
    end

    def current_snapshot
      @current_snapshot ||= snapshot(period_range)
    end

    def previous_snapshot
      @previous_snapshot ||= snapshot(previous_range)
    end

    # One point per chart bucket (day, week, or month) inside the selected period.
    def trend_buckets
      @trend_buckets ||= build_buckets
    end

    # Countable amount stacked by card type, using the same buckets as the sparklines.
    def card_chart
      names = {}
      totals = Hash.new(0)
      stacks = Hash.new { |hash, key| hash[key] = Hash.new(0) }
      countable.where(transaction_at: period_range).left_joins(:card_type).group(local_date_sql, "card_types.id", "card_types.name").pluck(
        local_date_sql,
        Arel.sql("card_types.id"),
        Arel.sql("card_types.name"),
        Arel.sql("COALESCE(SUM(transactions.transaction_amount_vnd), 0)")
      ).each do |day, id, name, amount|
        key = id || 0
        bucket = bucket_for(coerce_date(day))
        stacks[bucket][key] += amount.to_i
        totals[key] += amount.to_i
        names[key] ||= name.presence || I18n.t("dashboard.unassigned.card_type")
      end
      legend = totals.sort_by { |_key, amount| -amount }.map { |key, amount| { key: key, name: names[key], total: amount } }
      buckets = bucket_keys.map do |key|
        amounts = stacks[key]
        { date: key, label: bucket_label(key), stacks: amounts, total: amounts.values.sum }
      end
      { legend: legend, buckets: buckets }
    end

    def chart_start
      @date - 13
    end

    # One point per day, including days with no transactions. Amount uses the
    # same status exclusion as total_amount_today.
    def daily_amounts
      grouped = countable.where(transaction_at: chart_range).group(local_date_sql).pluck(
        local_date_sql,
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(transactions.transaction_amount_vnd), 0)")
      )
      by_date = grouped.to_h do |day, count, amount|
        [coerce_date(day), { count: count.to_i, amount: amount.to_i }]
      end
      (chart_start..@date).map do |day|
        row = by_date[day] || { count: 0, amount: 0 }
        { date: day, count: row[:count], amount: row[:amount] }
      end
    end

    def status_rows
      counts = Transaction.where(transaction_at: window_range).group(:status).count
      Transaction::STATUSES.filter_map do |status|
        count = counts[status].to_i
        next if count.zero?

        { status: status, count: count }
      end
    end

    def dealer_rows
      breakdown(:dealer, "dealers")
    end

    def merchant_rows
      breakdown(:merchant, "merchants")
    end

    def card_type_rows
      breakdown(:card_type, "card_types")
    end

    # Stored totals for approved transactions in the 30-day window.
    # Base fee is the difference of two stored amount columns, not a new rate.
    def period_totals
      gross, after_fee, profit, dealer_amount, count = Transaction.where(status: "approved", transaction_at: window_range).pick(
        Arel.sql("COALESCE(SUM(transaction_amount_vnd), 0)"),
        Arel.sql("COALESCE(SUM(amount_after_base_fee_vnd), 0)"),
        Arel.sql("COALESCE(SUM(profit_amount_vnd), 0)"),
        Arel.sql("COALESCE(SUM(dealer_amount_vnd), 0)"),
        Arel.sql("COUNT(*)")
      )
      {
        count: count.to_i,
        gross: gross.to_i,
        base_fee: gross.to_i - after_fee.to_i,
        profit: profit.to_i,
        dealer_amount: dealer_amount.to_i
      }
    end

    private

    # Same population as total_amount_today: drop rejected, failed, and excluded.
    def countable
      Transaction.where.not(status: %w[rejected failed excluded])
    end

    def chart_range
      Time.zone.local(chart_start.year, chart_start.month, chart_start.day)..Time.zone.local(@date.year, @date.month, @date.day).end_of_day
    end

    def window_range
      Time.zone.local(window_start.year, window_start.month, window_start.day)..Time.zone.local(@date.year, @date.month, @date.day).end_of_day
    end

    def breakdown(association, table)
      countable.where(transaction_at: period_range)
        .left_joins(association)
        .group("#{table}.id", "#{table}.name")
        .order(Arel.sql("COALESCE(SUM(transactions.transaction_amount_vnd), 0) DESC"))
        .pluck(
          Arel.sql("#{table}.id"),
          Arel.sql("#{table}.name"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(transactions.transaction_amount_vnd), 0)"),
          Arel.sql("COALESCE(SUM(transactions.transaction_amount_vnd) FILTER (WHERE transactions.status = 'approved'), 0)"),
          Arel.sql("COALESCE(SUM(transactions.profit_amount_vnd) FILTER (WHERE transactions.status = 'approved'), 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE transactions.status = 'approved')")
        ).map do |id, name, count, amount, approved_amount, profit, approved_count|
          {
            id: id,
            name: name.presence || I18n.t("dashboard.unassigned.#{association}"),
            count: count.to_i,
            amount: amount.to_i,
            approved_amount: approved_amount.to_i,
            profit: profit.to_i,
            approved_count: approved_count.to_i
          }
        end
    end

    def local_date_sql
      zone = ActiveRecord::Base.connection.quote(Time.zone.tzinfo.name)
      Arel.sql("(transactions.transaction_at AT TIME ZONE 'UTC' AT TIME ZONE #{zone})::date")
    end

    def coerce_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end

    def period_range
      day_range(period_start, period_end)
    end

    def previous_range
      day_range(previous_start, previous_end)
    end

    def day_range(from, to)
      Time.zone.local(from.year, from.month, from.day)..Time.zone.local(to.year, to.month, to.day).end_of_day
    end

    def snapshot(range)
      gross, count, approved_gross, after_fee, approved_count, decided = Transaction.where(transaction_at: range).where.not(status: "excluded").pick(
        Arel.sql("COALESCE(SUM(transaction_amount_vnd) FILTER (WHERE transactions.status NOT IN ('rejected', 'failed')), 0)"),
        Arel.sql("COUNT(*) FILTER (WHERE transactions.status NOT IN ('rejected', 'failed'))"),
        Arel.sql("COALESCE(SUM(transaction_amount_vnd) FILTER (WHERE transactions.status = 'approved'), 0)"),
        Arel.sql("COALESCE(SUM(amount_after_base_fee_vnd) FILTER (WHERE transactions.status = 'approved'), 0)"),
        Arel.sql("COUNT(*) FILTER (WHERE transactions.status = 'approved')"),
        Arel.sql("COUNT(*) FILTER (WHERE transactions.status NOT IN ('pending', 'processing'))")
      )
      approved_gross = approved_gross.to_i
      after_fee = after_fee.to_i
      approved_count = approved_count.to_i
      decided = decided.to_i
      {
        gross: gross.to_i,
        count: count.to_i,
        approved_gross: approved_gross,
        after_fee: after_fee,
        base_fee: approved_gross - after_fee,
        approved_count: approved_count,
        decided: decided,
        approval_rate: decided.zero? ? nil : approved_count.to_f / decided
      }
    end

    def daily_facts
      @daily_facts ||= Transaction.where(transaction_at: period_range).where.not(status: "excluded").group(local_date_sql).pluck(
        local_date_sql,
        Arel.sql("COALESCE(SUM(transaction_amount_vnd) FILTER (WHERE transactions.status NOT IN ('rejected', 'failed')), 0)"),
        Arel.sql("COUNT(*) FILTER (WHERE transactions.status NOT IN ('rejected', 'failed'))"),
        Arel.sql("COALESCE(SUM(transaction_amount_vnd) FILTER (WHERE transactions.status = 'approved'), 0)"),
        Arel.sql("COALESCE(SUM(amount_after_base_fee_vnd) FILTER (WHERE transactions.status = 'approved'), 0)"),
        Arel.sql("COUNT(*) FILTER (WHERE transactions.status = 'approved')"),
        Arel.sql("COUNT(*) FILTER (WHERE transactions.status NOT IN ('pending', 'processing'))")
      ).to_h do |day, gross, count, approved_gross, after_fee, approved_count, decided|
        [coerce_date(day), {
          gross: gross.to_i,
          count: count.to_i,
          base_fee: approved_gross.to_i - after_fee.to_i,
          after_fee: after_fee.to_i,
          approved_count: approved_count.to_i,
          decided: decided.to_i
        }]
      end
    end

    def build_buckets
      grouped = Hash.new { |hash, key| hash[key] = empty_fact }
      (period_start..period_end).each do |day|
        fact = daily_facts[day] || empty_fact
        bucket = grouped[bucket_for(day)]
        bucket[:gross] += fact[:gross]
        bucket[:count] += fact[:count]
        bucket[:base_fee] += fact[:base_fee]
        bucket[:after_fee] += fact[:after_fee]
        bucket[:approved_count] += fact[:approved_count]
        bucket[:decided] += fact[:decided]
      end
      bucket_keys.map do |key|
        fact = grouped[key]
        fact.merge(
          date: key,
          label: bucket_label(key),
          approval_rate: fact[:decided].zero? ? nil : fact[:approved_count].to_f / fact[:decided]
        )
      end
    end

    def empty_fact
      { gross: 0, count: 0, base_fee: 0, after_fee: 0, approved_count: 0, decided: 0 }
    end

    def bucket_for(day)
      case bucket_size
      when :week then day.beginning_of_week(:monday)
      when :month then day.beginning_of_month
      else day
      end
    end

    def bucket_size
      case @period_key
      when "90d" then :week
      when "12m" then :month
      else :day
      end
    end

    def bucket_keys
      keys = []
      cursor = bucket_for(period_start)
      last = bucket_for(period_end)
      while cursor <= last
        keys << cursor
        cursor = case bucket_size
        when :week then cursor + 7
        when :month then cursor.next_month
        else cursor + 1
        end
      end
      keys
    end

    def bucket_label(day)
      bucket_size == :month ? day.strftime("%m/%Y") : day.strftime("%d/%m")
    end
  end
end
