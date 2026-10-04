# Converts between UI percentages and stored decimal rates using BigDecimal only.
module Percentage
  module_function

  # "0,88" / "0.88" / "0.88%" => BigDecimal("0.0088"); blank => nil
  def percent_to_rate(value)
    text = value.to_s.strip.delete("%").tr(",", ".").delete(" ")
    return nil if text.blank?
    return nil unless text.match?(/\A-?\d+(\.\d+)?\z/)

    BigDecimal(text) / 100
  end

  # BigDecimal("0.0088") => "0.88"
  def rate_to_percent_string(rate)
    return nil if rate.nil?

    format_decimal(BigDecimal(rate.to_s) * 100)
  end

  def format_decimal(decimal)
    text = decimal.to_s("F")
    text = text.sub(/\.?0+\z/, "") if text.include?(".")
    text
  end
end
