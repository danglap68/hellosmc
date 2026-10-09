module ApplicationHelper
  include Pagy::Frontend

  STATUS_COLORS = {
    "pending" => "secondary",
    "processing" => "blue",
    "needs_review" => "yellow",
    "approved" => "green",
    "rejected" => "red",
    "hold" => "orange",
    "exported" => "teal",
    "failed" => "red"
  }.freeze

  OCR_STATUS_COLORS = {
    "pending" => "secondary", "processing" => "blue", "completed" => "green",
    "needs_review" => "yellow", "failed" => "red", "duplicate" => "purple"
  }.freeze

  EXPORT_STATUS_COLORS = { "pending" => "secondary", "processing" => "blue", "completed" => "green", "failed" => "red" }.freeze

  def tabler_form_with(**options, &block)
    form_with(**options, builder: TablerFormBuilder, &block)
  end

  def icon(name, extra_class = nil)
    content_tag(:i, nil, class: [ "ti", "ti-#{name}", "icon", extra_class ].compact.join(" "), "aria-hidden": "true")
  end

  # 11445000 => "11.445.000 ₫"
  def format_vnd(amount, unit: true)
    return content_tag(:span, "—", class: "text-secondary") if amount.nil?

    number = number_with_delimiter(Integer(amount), delimiter: ".")
    unit ? "#{number} ₫" : number
  end

  # BigDecimal("0.0088") => "0,88%"
  def format_rate(rate)
    return content_tag(:span, "—", class: "text-secondary") if rate.nil?

    whole, decimals = Percentage.rate_to_percent_string(rate).split(".")
    "#{whole},#{decimals.to_s.ljust(2, '0')}%"
  end

  def format_datetime(time, format: :default)
    return content_tag(:span, "—", class: "text-secondary") if time.nil?

    l(time.in_time_zone, format: format)
  end

  def format_date(date)
    return content_tag(:span, "—", class: "text-secondary") if date.nil?

    l(date.to_date)
  end

  def status_badge(status)
    color = STATUS_COLORS.fetch(status.to_s, "secondary")
    content_tag(:span, t("activerecord.enums.transaction.status.#{status}"), class: "badge bg-#{color}-lt")
  end

  def ocr_status_badge(status)
    color = OCR_STATUS_COLORS.fetch(status.to_s, "secondary")
    content_tag(:span, t("activerecord.enums.bill_image.ocr_status.#{status}"), class: "badge bg-#{color}-lt")
  end

  def export_status_badge(status)
    color = EXPORT_STATUS_COLORS.fetch(status.to_s, "secondary")
    content_tag(:span, t("activerecord.enums.excel_export.status.#{status}"), class: "badge bg-#{color}-lt")
  end

  def active_badge(active)
    if active
      content_tag(:span, t("common.active"), class: "badge bg-green-lt")
    else
      content_tag(:span, t("common.inactive"), class: "badge bg-secondary-lt")
    end
  end

  # Green at/above auto-approve, yellow at/above review threshold, red below.
  def confidence_badge(value)
    return content_tag(:span, "—", class: "badge bg-secondary-lt") if value.nil?

    decimal = BigDecimal(value.to_s)
    color =
      if decimal >= AppConfig.ocr_auto_approve_threshold then "green"
      elsif decimal >= AppConfig.ocr_review_threshold then "yellow"
      else "red"
      end
    content_tag(:span, "#{(decimal * 100).round}%", class: "badge bg-#{color}-lt", title: t("common.confidence"))
  end

  def enum_label(model, attribute, value)
    return "—" if value.blank?

    t("activerecord.enums.#{model}.#{attribute}.#{value}", default: value.to_s.humanize)
  end

  def enum_options(model, attribute, values)
    values.map { |value| [ enum_label(model, attribute, value), value ] }
  end

  def review_reason_label(code)
    t("review_reasons.#{code}", default: code.to_s.humanize)
  end

  def yes_no(value)
    value ? t("common.yes") : t("common.no")
  end

  def json_block(data)
    return content_tag(:p, t("common.no_data"), class: "text-secondary mb-0") if data.blank?

    content_tag(:pre, JSON.pretty_generate(data), class: "json-block mb-0")
  end

  def nav_link(label, path, icon_name, resource:, active: nil)
    return unless can?(:read, resource)

    is_active = active.nil? ? current_page?(path) || request.path.start_with?("#{path}/") : active
    content_tag(:li, class: [ "nav-item", ("active" if is_active) ].compact.join(" ")) do
      link_to(path, class: "nav-link", aria: { current: ("page" if is_active) }) do
        safe_join([
          content_tag(:span, icon(icon_name), class: "nav-link-icon d-md-none d-lg-inline-block"),
          content_tag(:span, label, class: "nav-link-title")
        ])
      end
    end
  end

  def nav_section(label)
    content_tag(:li, class: "nav-item nav-section") do
      content_tag(:div, label, class: "nav-section-title")
    end
  end

  def empty_state(title, subtitle = nil, icon_name: "mood-empty")
    content_tag(:div, class: "empty") do
      safe_join([
        content_tag(:div, icon(icon_name), class: "empty-icon"),
        content_tag(:p, title, class: "empty-title"),
        subtitle ? content_tag(:p, subtitle, class: "empty-subtitle text-secondary") : nil
      ].compact)
    end
  end

  def pagination(pagy)
    return if pagy.nil? || pagy.pages <= 1

    content_tag(:div, class: "card-footer d-flex align-items-center") do
      safe_join([
        content_tag(:p, pagy_info(pagy).html_safe, class: "m-0 text-secondary"),
        content_tag(:div, pagy_bootstrap_nav(pagy).html_safe, class: "ms-auto")
      ])
    end
  end

  def dealer_options
    Dealer.ordered.map { |dealer| [ dealer.active? ? dealer.name : "#{dealer.name} (#{t('common.inactive')})", dealer.id ] }
  end

  def merchant_options(scope = Merchant.all)
    scope.ordered.map { |merchant| [ "#{merchant.name} [#{merchant.code}]", merchant.id ] }
  end

  def export_layout_options
    ExcelExport::LAYOUTS.map { |layout| [ t("activerecord.enums.excel_export.layout.#{layout}"), layout ] }
  end

  def card_type_options(value: :id)
    CardType.ordered.map { |card_type| [ card_type.name, card_type.public_send(value) ] }
  end

  # Phí gốc luôn gợi ý mức sheet. Phí gốc theo thẻ và phí đại lý chỉ đổi khi mọi loại thẻ đang chọn là MB hoặc Napas.
  def fee_rate_placeholders(card_types)
    keys = Array(card_types).compact.map { |card_type| card_type.respond_to?(:key) ? card_type.key : card_type.to_s }
    special = keys.present? && keys.all? { |key| key.in?(%w[mb napas]) }
    { base: "1,21", card: (special ? "0,88" : "1,21"), dealer: (special ? "1,2" : "1,4") }
  end

  def fee_rule_label(fee_rule)
    return "—" if fee_rule.nil?

    "##{fee_rule.id} · #{format_rate(fee_rule.base_fee_rate)} · #{t("fee_rules.levels.#{fee_rule.specificity_level}")}"
  end

  def audit_actor(audit_log)
    audit_log.system? ? content_tag(:span, t("audit_logs.system"), class: "badge bg-azure-lt") : (audit_log.actor_name || "—")
  end

  AUDITABLE_MODELS = %w[Transaction FeeRule Merchant MerchantAlias Dealer TelegramChat TelegramMessage
                        CardType ExcelExport User BillImage].freeze

  # Human model name for an audit entry; only known models are constantized.
  def auditable_label(type)
    return "—" if type.blank?

    type.in?(AUDITABLE_MODELS) ? type.constantize.model_name.human : type
  end

  def audit_action_label(action)
    t("audit_logs.actions.#{action.tr('.', '_')}", default: action)
  end

  def audit_value(value)
    case value
    when nil then content_tag(:span, "null", class: "text-secondary")
    when Hash, Array then content_tag(:code, value.to_json)
    else value.to_s
    end
  end
end
