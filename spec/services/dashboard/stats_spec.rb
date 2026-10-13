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
end
