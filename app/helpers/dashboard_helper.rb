module DashboardHelper
  CHART_COLORS = ["var(--ev-s1)", "var(--ev-s2)", "var(--ev-s3)", "var(--ev-s4)", "var(--ev-neg)"].freeze

  def sparkline(values)
    numbers = Array(values).map(&:to_f)
    return "".html_safe if numbers.empty?

    max = numbers.max
    min = numbers.min
    span = (max - min).zero? ? 1.0 : (max - min)
    width = 160.0
    height = 40.0
    step = numbers.size == 1 ? 0 : width / (numbers.size - 1)
    coords = numbers.each_with_index.map do |value, index|
      x = index * step
      y = height - 4 - ((value - min) / span) * (height - 10)
      [x, y]
    end
    line = coords.map { |x, y| format("%<x>.1f,%<y>.1f", x: x, y: y) }.join(" ")
    area = "#{format("%.1f", coords.first[0])},#{height} #{line} #{format("%.1f", coords.last[0])},#{height}"
    tag.svg(class: "sparkline", viewBox: "0 0 #{width} #{height}", preserveAspectRatio: "none", aria: { hidden: true }) do
      safe_join([
        tag.polygon(points: area, fill: "var(--ev-ov-spark-wash)"),
        tag.polyline(points: line, fill: "none", stroke: "var(--ev-ov-spark)", "stroke-width": "1.75", "stroke-linejoin": "round", "stroke-linecap": "round")
      ])
    end
  end

  def share_percent(rate)
    return content_tag(:span, "—", class: "text-secondary") if rate.nil?

    rounded = (rate.to_f * 100).round(1)
    text = (rounded % 1).zero? ? rounded.to_i.to_s : format("%.1f", rounded).tr(".", ",")
    "#{text}%"
  end

  def period_delta(current, previous, mode: :amount)
    if mode == :rate
      return { direction: "flat", text: t("dashboard.delta_flat") } if current.nil? && previous.nil?
      return { direction: "new", text: t("dashboard.delta_new") } if previous.nil?
      current = current.to_f
      previous = previous.to_f
      return { direction: "flat", text: t("dashboard.delta_flat") } if current == previous
      points = ((current - previous) * 100).round(1)
      direction = points.positive? ? "up" : (points.negative? ? "down" : "flat")
      amount = format("%.1f", points.abs).tr(".", ",")
      text = direction == "flat" ? t("dashboard.delta_flat") : t("dashboard.delta_points", direction: t("dashboard.delta_#{direction}"), amount: amount)
      return { direction: direction, text: text }
    end

    current = current.to_f
    previous = previous.to_f
    return { direction: "flat", text: t("dashboard.delta_flat") } if current == previous
    return { direction: "new", text: t("dashboard.delta_new") } if previous.zero?

    change = ((current - previous) / previous.abs * 100).round(1)
    direction = change.positive? ? "up" : (change.negative? ? "down" : "flat")
    amount = (change.abs % 1).zero? ? change.abs.to_i.to_s : format("%.1f", change.abs).tr(".", ",")
    { direction: direction, text: t("dashboard.delta_percent", direction: t("dashboard.delta_#{direction}"), amount: amount) }
  end

  def stacked_amount_chart(chart)
    buckets = chart[:buckets]
    legend = chart[:legend]
    return "".html_safe if buckets.empty?

    max = [buckets.map { |bucket| bucket[:total] }.max.to_f, 1].max
    slot = 36
    height = 168
    baseline = 148
    width = buckets.size * slot
    label_step = buckets.size > 16 ? (buckets.size / 8.0).ceil : 1
    parts = []
    buckets.each_with_index do |bucket, index|
      x = index * slot + 6
      cursor = baseline
      if bucket[:total].zero?
        parts << %(<rect class="column-chart-bar is-empty" x="#{x}" y="#{baseline - 2}" width="22" height="2" rx="1"></rect>)
      else
        legend.each_with_index do |series, series_index|
          amount = bucket[:stacks][series[:key]].to_i
          next if amount.zero?

          bar = (amount / max) * 132
          bar = 1.5 if bar < 1.5
          cursor -= bar
          color = CHART_COLORS[series_index % CHART_COLORS.size]
          parts << %(<rect x="#{x}" y="#{cursor.round(2)}" width="22" height="#{bar.round(2)}" rx="3" fill="#{color}"><title>#{ERB::Util.html_escape(series[:name])}: #{ERB::Util.html_escape(number_with_delimiter(amount, delimiter: "."))} ₫</title></rect>)
        end
      end
      if index % label_step == 0 || index == buckets.size - 1
        parts << %(<text class="column-chart-label" x="#{x + 11}" y="#{height - 4}" text-anchor="middle">#{ERB::Util.html_escape(bucket[:label])}</text>)
      end
    end
    %(<svg class="column-chart" viewBox="0 0 #{width} #{height}" role="img" aria-label="#{ERB::Util.html_escape(t("dashboard.chart_by_card"))}">#{parts.join}</svg>).html_safe
  end
end
