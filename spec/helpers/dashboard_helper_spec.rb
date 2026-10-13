require "rails_helper"

RSpec.describe DashboardHelper, "#stacked_amount_chart" do
  def chart_for(days)
    buckets = days.times.map do |index|
      amount = index == days - 1 ? 3_500_000 : 0
      { label: format("%02d/10", index + 1), stacks: { 1 => amount }, total: amount }
    end
    { legend: [ { key: 1, name: "Thẻ thường", total: 3_500_000 } ], buckets: buckets }
  end

  it "uses one wide frame for 7 days and 30 days so the columns stay short" do
    week = helper.stacked_amount_chart(chart_for(7))
    month = helper.stacked_amount_chart(chart_for(30))

    expect(week).to include('viewBox="0 0 640 168"')
    expect(month).to include('viewBox="0 0 640 168"')
    widths = week.scan(/class="column-chart-stack"[^>]*width="([^"]+)"/).flatten.map(&:to_f)
    expect(widths).not_to be_empty
    expect(widths.max).to be <= 22
  end
end