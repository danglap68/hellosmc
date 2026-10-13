module CommandPaletteHelper
  def command_palette_items
    pages = []
    actions = []

    shell_main_items.each do |item|
      pages << palette_entry("pages", item[:label], item[:url], t("palette.pages"))
    end

    settings_tabs.each do |tab|
      actions << palette_entry("actions", t("palette.open_settings", name: tab[:label]), tab[:url], t("navigation.settings"))
      tab[:items].each do |item|
        pages << palette_entry("pages", item[:label_text], item[:url], "#{t("navigation.settings")} · #{tab[:label]}")
      end
    end

    if !feature_hidden?(:bill_uploads) && can?(:manage, :bill_uploads)
      actions << palette_entry("actions", t("palette.upload_bill"), new_admin_bill_upload_path, t("navigation.bill_uploads"))
    end
    if can?(:manage, :excel_exports)
      actions << palette_entry("actions", t("palette.new_export"), new_admin_excel_export_path, t("navigation.excel_exports"))
    end
    if can?(:read, :transactions)
      actions << palette_entry("actions", t("palette.filter_review"), admin_transactions_path(status: "needs_review"), t("navigation.transactions"))
      actions << palette_entry("actions", t("palette.filter_approved"), admin_transactions_path(status: "approved"), t("navigation.transactions"))
    end
    if can?(:manage, :reviews)
      actions << palette_entry("actions", t("palette.open_review"), admin_reviews_path, t("navigation.reviews"))
    end

    (pages + actions).uniq { |entry| [entry[:group], entry[:url], entry[:label]] }
  end

  def command_palette_labels
    {
      recent: t("palette.recent"),
      pages: t("palette.pages"),
      actions: t("palette.actions"),
      empty: t("palette.empty")
    }
  end

  private

  def palette_entry(group, label, url, hint)
    {
      group: group,
      label: label,
      url: url,
      hint: hint,
      search: VietnameseText.normalize("#{label} #{hint}")
    }
  end
end
