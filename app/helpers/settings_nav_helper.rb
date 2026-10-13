module SettingsNavHelper
  # Daily work stays in the sidebar. Master data lives under Cài đặt.
  # Collection URLs move under /admin/settings/...; the old index paths redirect.
  SETTINGS_INDEXES = {
    "admin/dealers" => :admin_settings_organization_dealers_path,
    "admin/telegram_chats" => :admin_settings_organization_telegram_chats_path,
    "admin/merchants" => :admin_settings_organization_merchants_path,
    "admin/remitters" => :admin_settings_organization_remitters_path,
    "admin/transfer_codes" => :admin_settings_organization_transfer_codes_path,
    "admin/fee_rules" => :admin_settings_fees_rules_path,
    "admin/card_types" => :admin_settings_fees_card_types_path,
    "admin/users" => :admin_settings_system_users_path,
    "admin/roles" => :admin_settings_system_roles_path,
    "admin/audit_logs" => :admin_settings_system_audit_logs_path
  }.freeze

  GENERAL_SECTIONS = [
    { id: "ket-noi", label: "navigation.settings_connections" },
    { id: "telegram", label: "navigation.settings_telegram" },
    { id: "van-hanh", label: "navigation.settings_operations" },
    { id: "tinh-chinh", label: "navigation.settings_tuning" }
  ].freeze

  SETTINGS_TABS = [
    {
      key: :general,
      label: "navigation.settings_general",
      items: [
        { resource: :settings, icon: "adjustments", path: :admin_settings_path, controllers: %w[admin/settings], label: "navigation.settings_app" }
      ]
    },
    {
      key: :organization,
      label: "navigation.sections.organization",
      items: [
        { resource: :dealers, icon: "users", path: :admin_settings_organization_dealers_path, controllers: %w[admin/dealers] },
        { resource: :telegram_chats, icon: "brand-telegram", path: :admin_settings_organization_telegram_chats_path, controllers: %w[admin/telegram_chats] },
        { resource: :merchants, icon: "building-store", path: :admin_settings_organization_merchants_path, controllers: %w[admin/merchants admin/merchant_aliases] },
        { resource: :remitters, icon: "user-dollar", path: :admin_settings_organization_remitters_path, controllers: %w[admin/remitters] },
        { resource: :transfer_codes, icon: "hash", path: :admin_settings_organization_transfer_codes_path, controllers: %w[admin/transfer_codes] }
      ]
    },
    {
      key: :fees,
      label: "navigation.sections.fees",
      items: [
        { resource: :fee_rules, icon: "percentage", path: :admin_settings_fees_rules_path, controllers: %w[admin/fee_rules] },
        { resource: :card_types, icon: "credit-card", path: :admin_settings_fees_card_types_path, controllers: %w[admin/card_types] }
      ]
    },
    {
      key: :system,
      label: "navigation.sections.system",
      items: [
        { resource: :users, icon: "user-cog", path: :admin_settings_system_users_path, controllers: %w[admin/users] },
        { resource: :roles, icon: "shield", path: :admin_settings_system_roles_path, controllers: %w[admin/roles] },
        { resource: :audit_logs, icon: "history", path: :admin_settings_system_audit_logs_path, controllers: %w[admin/audit_logs] }
      ]
    }
  ].freeze

  def settings_tabs
    @settings_tabs ||= SETTINGS_TABS.filter_map do |tab|
      items = tab[:items].filter_map do |item|
        next unless can?(:read, item[:resource])

        item.merge(url: public_send(item[:path]), label_text: t(item[:label] || "navigation.#{item[:resource]}"))
      end
      next if items.empty?

      { key: tab[:key], label: t(tab[:label]), url: items.first[:url], items: items }
    end
  end

  def settings_context?
    controller_path.in?(SETTINGS_TABS.flat_map { |tab| tab[:items].flat_map { |item| item[:controllers] } })
  end

  def current_settings_tab
    settings_tabs.find { |tab| tab[:items].any? { |item| item[:controllers].include?(controller_path) } } || settings_tabs.first
  end

  def settings_subnav_items
    tab = current_settings_tab
    return [] unless tab

    if tab[:key] == :general && controller_path == "admin/settings"
      return GENERAL_SECTIONS.map do |section|
        { label: t(section[:label]), url: "#{admin_settings_path}##{section[:id]}", anchor: true, active: false }
      end
    end

    tab[:items].map do |item|
      { label: item[:label_text], url: item[:url], anchor: false, active: item[:controllers].include?(controller_path) }
    end
  end

  def settings_home_path
    settings_tabs.first&.dig(:url)
  end

  def settings_nav_link
    return if settings_tabs.empty?

    active = settings_context?
    link_to(settings_home_path, class: "shell-link", aria: { current: ("page" if active) }) do
      safe_join([
        content_tag(:span, icon("settings"), class: "shell-link-icon"),
        content_tag(:span, t("navigation.settings"), class: "shell-link-label")
      ])
    end
  end

  NAV_PINS_COOKIE = "nav_pins".freeze

  def shell_main_items
    @shell_main_items ||= [
      shell_item(:dashboard, t("navigation.dashboard"), admin_root_path, "layout-dashboard", active: controller_path == "admin/dashboard"),
      shell_item(:messages, t("navigation.messages"), admin_messages_path, "messages"),
      shell_item(:transactions, t("navigation.transactions"), admin_transactions_path, "arrows-exchange"),
      shell_item(:reviews, t("navigation.reviews"), admin_reviews_path, "scan", count: -> { shell_queue_count(:reviews) }),
      shell_item(:bill_albums, t("navigation.bill_albums"), admin_bill_albums_path, "photo"),
      shell_item(:remitter_transfers, t("navigation.remitter_transfers"), admin_remitter_transfers_path, "cash", count: -> { shell_queue_count(:transfers) }),
      shell_item(:bill_uploads, t("navigation.bill_uploads"), new_admin_bill_upload_path, "upload", active: controller_path == "admin/bill_uploads"),
      shell_item(:excel_exports, t("navigation.excel_exports"), admin_excel_exports_path, "file-spreadsheet")
    ].compact
  end

  def shell_pinned_keys
    cookies[NAV_PINS_COOKIE].to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end

  def shell_pinned_items
    by_key = shell_main_items.index_by { |item| item[:key] }
    shell_pinned_keys.filter_map { |key| by_key[key] }
  end

  private

  def shell_item(key, label, url, icon_name, active: nil, count: nil)
    return if feature_hidden?(key) || !can?(:read, key)

    is_active = active.nil? ? (request.path == url || request.path.start_with?("#{url}/")) : active
    { key: key.to_s, label: label, url: url, icon: icon_name, active: is_active, count: count ? count.call.to_i : 0 }
  end

  def shell_queue_count(key)
    @shell_queue_counts ||= {}
    @shell_queue_counts[key] ||= case key
    when :reviews then Transaction.where(status: "needs_review").count
    when :transfers then RemitterTransfer.where(status: "needs_review").count
    else 0
    end
  end
end
