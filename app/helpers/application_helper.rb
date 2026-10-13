module ApplicationHelper
  include Pagy::Frontend

  # Routes and controllers stay reachable by URL; only the UI entry points are hidden.
  HIDDEN_FEATURES = %i[bill_albums bill_uploads].freeze

  def feature_hidden?(feature)
    HIDDEN_FEATURES.include?(feature)
  end

  STATUS_COLORS = {
    "pending" => "secondary",
    "processing" => "blue",
    "needs_review" => "yellow",
    "approved" => "green",
    "rejected" => "red",
    "hold" => "orange",
    "failed" => "red",
    "excluded" => "secondary"
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

  # "SmartPOS" / "HKD bỏ qua bill" next to the status of an excluded bill.
  def skip_tag_badges(transaction)
    safe_join((transaction.tags & Transaction::SKIP_TAGS).map do |tag|
      content_tag(:span, t("transactions.tags.#{tag}"), class: "badge bg-secondary-lt ms-1")
    end)
  end

  def ocr_status_badge(status)
    color = OCR_STATUS_COLORS.fetch(status.to_s, "secondary")
    content_tag(:span, t("activerecord.enums.bill_image.ocr_status.#{status}"), class: "badge bg-#{color}-lt")
  end

  ALBUM_STATUS_COLORS = {
    "collecting" => "secondary", "processing" => "blue", "reconciled" => "green",
    "needs_review" => "yellow", "skipped" => "orange", "failed" => "red"
  }.freeze

  def album_status_badge(album)
    color = ALBUM_STATUS_COLORS.fetch(album.status.to_s, "secondary")
    content_tag(:span, enum_label(:bill_album, :status, album.status), class: "badge bg-#{color}-lt")
  end

  # "total" for the album's tổng kết (settlement/transfer), "child" for a bill
  # con, "unread" when OCR found nothing usable.
  def album_image_kind(album, image)
    types = (image.duplicate_of || image).documents.map { |doc| doc["document_type"] }
    return "total" if image.id == album.transfer_bill_image_id || types.intersect?(%w[settlement transfer])
    return album_children_dropped?(album) ? "child_unused" : "child" if types.include?("child_receipt")

    album_children_dropped?(album) ? "unused" : "unread"
  end

  # The label of a photo on the album pages: the settlement is the "Bill kết",
  # a bank transfer total the "Hình chuyển tiền"; what the album does not use
  # (child bills of a complete settlement, a calculator, a QR code) is "bỏ qua".
  def album_image_label(album, image)
    kind = album_image_kind(album, image)
    return t("bill_images.album.kinds.#{kind}") unless kind == "total"

    types = (image.duplicate_of || image).documents.map { |doc| doc["document_type"] }
    t("bill_images.album.kinds.#{types.include?('settlement') ? 'settlement' : 'transfer'}")
  end

  # A photo the album skips has no OCR verdict worth showing (a calculator reads
  # as "Cần kiểm tra"); a failed run or a duplicate still is.
  def album_image_skipped?(album, image)
    album_image_kind(album, image).in?(%w[child_unused unused]) && !image.ocr_failed? && !image.ocr_duplicate?
  end

  # The settlement printed everything, so the album's child bills were dropped.
  def album_children_dropped?(album)
    album.metadata["children_dropped"] == true
  end

  # Amounts OCR read on one album photo (a photo can hold several bills). With
  # the child bills dropped only the settlement's own amount is shown, even when
  # the child bills are on the same photo.
  def album_image_amounts(image, album = nil)
    documents = (image.duplicate_of || image).documents
    documents = documents.select { |doc| doc["document_type"].in?(%w[settlement transfer]) } if album && album_children_dropped?(album)
    documents.filter_map { |doc| doc["total_amount_vnd"] }
  end

  def reconciliation_status_badge(album)
    return content_tag(:span, "—", class: "badge bg-secondary-lt") if album.reconciliation_status.blank?

    color = album.reconciliation_status.in?(%w[matched settlement_complete]) ? "green" : "yellow"
    content_tag(:span, enum_label(:bill_album, :reconciliation_status, album.reconciliation_status), class: "badge bg-#{color}-lt")
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

  def dealer_options(transaction = nil)
    # Once the HKD is known, only its agents are offered; otherwise every dealer.
    scope = transaction&.merchant ? transaction.merchant.dealers.distinct : Dealer.all
    scope.ordered.map { |dealer| dealer_option(dealer) }
  end

  # Agents per HKD for the review form, so the dealer list follows the HKD the
  # reviewer picks in the browser: { "merchant_id" => [[label, id], ...], "" => every dealer }.
  def dealer_options_by_merchant
    dealers = Dealer.ordered.to_a
    by_id = dealers.index_by(&:id)
    links = MerchantDealer.distinct.pluck(:merchant_id, :dealer_id).group_by(&:first)
    options = links.transform_keys(&:to_s).transform_values do |pairs|
      pairs.map { |(_merchant_id, dealer_id)| by_id[dealer_id] }.compact.uniq.sort_by(&:name).map { |dealer| dealer_option(dealer) }
    end
    options.merge("" => dealers.map { |dealer| dealer_option(dealer) })
  end

  def dealer_option(dealer)
    [ dealer.active? ? dealer.name : "#{dealer.name} (#{t('common.inactive')})", dealer.id ]
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
                        CardType ExcelExport User Role BillImage].freeze

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
