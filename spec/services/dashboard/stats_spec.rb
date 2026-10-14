require "rails_helper"

RSpec.describe Dashboard::Stats do
  def recorded_profit(amount, at:, status: "approved", **attributes)
    create(:transaction, :calculated, status: status, transaction_at: at,
                                     profit_amount_vnd: amount, **attributes)
  end

  it "totals stored approved profit, including exported rows and losses, and matches the breakdowns" do
    today = Time.current
    recorded_profit(19_001, at: today)
    recorded_profit(5_000, at: today, exported_at: today)
    recorded_profit(-2_000, at: today)
    %w[pending processing needs_review hold rejected failed excluded].each do |status|
      recorded_profit(1_000_000, at: today, status: status)
    end

    stats = described_class.new

    expect(stats.current_snapshot[:profit]).to eq(22_001)
    expect(stats.dealer_rows.sum { |row| row[:profit] }).to eq(22_001)
    expect(stats.merchant_rows.sum { |row| row[:profit] }).to eq(22_001)
    expect(stats.trend_buckets.sum { |row| row[:profit] }).to eq(22_001)
  end

  described_class::PERIODS.each do |period|
    it "uses Vietnam date boundaries and the selected #{period} window for profit and trends" do
      stats = described_class.new(period: period)
      first = Time.zone.local(stats.period_start.year, stats.period_start.month, stats.period_start.day)
      last = Time.current.end_of_day
      recorded_profit(7_000, at: first)
      recorded_profit(3_000, at: last)
      recorded_profit(2_000, at: first - 1.second)
      recorded_profit(9_000, at: last + 1.second)

      expect(stats.current_snapshot[:profit]).to eq(10_000)
      expect(stats.previous_snapshot[:profit]).to eq(2_000)
      expect(stats.trend_buckets.sum { |row| row[:profit] }).to eq(10_000)
    end
  end

  it "returns zero profit for an empty window and fills empty trend buckets" do
    stats = described_class.new(period: "7d")

    expect(stats.current_snapshot[:profit]).to eq(0)
    expect(stats.previous_snapshot[:profit]).to eq(0)
    expect(stats.trend_buckets.map { |row| row[:profit] }).to eq([ 0 ] * 7)
  end

  it "reconciles today's approved and waiting amounts, including failed bills, across all breakdowns" do
    recorded_profit(1_000, at: Time.current, transaction_amount_vnd: 100_000)
    %w[pending processing needs_review hold failed].each do |status|
      recorded_profit(9_999, at: Time.current, status: status, transaction_amount_vnd: 20_000)
    end
    %w[rejected excluded].each do |status|
      recorded_profit(9_999, at: Time.current, status: status, transaction_amount_vnd: 999_999)
    end
    recorded_profit(8_000, at: 1.day.ago)
    stats = described_class.new
    totals = stats.current_snapshot

    expect(stats.period_key).to eq("today")
    expect(totals).to include(gross: 200_000, approved_gross: 100_000, waiting_gross: 100_000,
                             count: 6, approved_count: 1, waiting_count: 5, profit: 1_000, auto_approved_count: 1)
    expect(totals[:gross]).to eq(totals[:approved_gross] + totals[:waiting_gross])
    expect(stats.settlement_rows.values.sum { |row| row[:amount] }).to eq(totals[:gross])
    expect(stats.dealer_rows.sum { |row| row[:amount] }).to eq(totals[:gross])
    expect(stats.merchant_rows.sum { |row| row[:amount] }).to eq(totals[:gross])
    expect(stats.card_chart[:buckets].sum { |row| row[:total] }).to eq(totals[:gross])
    expect(stats.trend_buckets.sum { |row| row[:gross] }).to eq(totals[:gross])
  end

  it "keeps undated and unread transactions visible on receipt day without inventing money" do
    create(:transaction, status: "failed", transaction_at: nil, transaction_amount_vnd: nil)
    create(:transaction, status: "needs_review", transaction_at: nil, transaction_amount_vnd: 25_000)
    create(:transaction, status: "failed", transaction_at: nil, created_at: 1.day.ago, transaction_amount_vnd: nil)

    stats = described_class.new
    expect(stats.current_snapshot).to include(gross: 25_000, waiting_gross: 25_000, count: 2, unread_count: 1)
    expect(stats.card_chart[:buckets].sole[:total]).to eq(25_000)
    expect(stats.trend_buckets.sole[:gross]).to eq(25_000)
    filtered = Transactions::Filter.new(date_from: stats.date.iso8601, date_to: stats.date.iso8601).apply
    expect(filtered.count).to eq(2)
  end

  it "reports images still awaiting download separately from images awaiting OCR" do
    photo = telegram_fixture("photo_update")
    create(:telegram_message, processing_status: "queued", raw_payload: photo)
    create(:telegram_message, processing_status: "queued", raw_payload: photo, created_at: 1.day.ago)
    stored = create(:telegram_message, processing_status: "queued", raw_payload: photo)
    create(:bill_image, telegram_message: stored, ocr_status: "pending")

    stats = described_class.new
    expect(stats.queued_downloads).to eq(1)
    expect(stats.unprocessed_images).to eq(1)
    expect(stats.current_snapshot[:gross]).to eq(0)
  end
end
