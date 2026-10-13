module ListToolbarHelper
  IGNORED_QUERY_KEYS = %w[page utf8 authenticity_token commit].freeze

  # One GET toolbar: search, a filter popover, a sort menu, and chips for
  # filters that are already applied. Draft edits inside the popover are
  # submitted only by Áp dụng. Search and sort keep the current query.
  def list_toolbar(url:, search:, filters: [], sorts: [], default_sort:)
    prepared = filters.map { |filter| prepare_filter(filter) }
    chips = prepared.filter_map { |filter| filter[:chip] }
    sort_options = prepare_sorts(sorts, default_sort:, url:)
    current_sort = sort_options.find { |sort| sort[:current] } || sort_options.first
    filter_names = prepared.flat_map { |filter| filter[:param_names] }

    render "admin/shared/list_toolbar",
           url: url,
           search: search,
           filters: prepared,
           chips: chips,
           sorts: sort_options,
           current_sort: current_sort,
           filter_names: filter_names
  end

  def toolbar_hidden_fields(except:)
    safe_join(toolbar_kept_params(except: except).flat_map { |key, value| hidden_query_inputs(key, value) })
  end

  def toolbar_path(url, except: [], extra: {})
    query = toolbar_kept_params(except: except).merge(extra.stringify_keys)
    query = query.reject { |_, value| value.blank? }
    query.empty? ? url : "#{url}?#{query.to_query}"
  end

  private

  def toolbar_kept_params(except:)
    request.query_parameters.except(*IGNORED_QUERY_KEYS, *except.map(&:to_s))
  end

  def hidden_query_inputs(key, value)
    if value.is_a?(Array)
      value.map { |item| tag.input(type: "hidden", name: "#{key}[]", value: item) }
    else
      [tag.input(type: "hidden", name: key, value: value)]
    end
  end

  def prepare_sorts(sorts, default_sort:, url:)
    keys = sorts.map { |sort| sort[:key].to_s }
    current = params[:sort].to_s
    current = default_sort.to_s unless keys.include?(current)
    sorts.map do |sort|
      key = sort[:key].to_s
      extra = key == default_sort.to_s ? {} : { "sort" => key }
      { key: key, label: sort[:label], current: key == current, url: toolbar_path(url, except: ["sort"], extra: extra) }
    end
  end

  def prepare_filter(filter)
    case filter[:type].to_sym
    when :single then prepare_single(filter)
    when :text then prepare_text(filter)
    when :date_range then prepare_date_range(filter)
    when :amount_range then prepare_amount_range(filter)
    when :boolean then prepare_boolean(filter)
    else raise ArgumentError, "Unknown list filter type: #{filter[:type]}"
    end
  end

  def prepare_single(filter)
    value = filter[:value].to_s
    choices = Array(filter[:options]).map { |label, option| { label: label.to_s, value: option.to_s } }
    choices.unshift({ label: t("toolbar.all"), value: "" }) unless filter[:include_blank] == false
    choices.each { |choice| choice[:selected] = choice[:value] == value }
    selected = choices.find { |choice| choice[:selected] && choice[:value].present? }
    show_chip = filter.fetch(:chip, true) && selected
    {
      key: filter[:key] || filter[:name],
      type: :single,
      name: filter[:name],
      label: filter[:label],
      summary: selected ? selected[:label] : t("toolbar.all"),
      choices: choices,
      param_names: [filter[:name]],
      chip: (show_chip ? { text: "#{filter[:label]}: #{selected[:label]}", drop: [filter[:name]] } : nil)
    }
  end

  def prepare_text(filter)
    value = filter[:value].to_s
    {
      key: filter[:key] || filter[:name],
      type: :text,
      name: filter[:name],
      label: filter[:label],
      value: value,
      summary: value.presence || t("toolbar.not_set"),
      param_names: [ filter[:name] ],
      chip: (value.present? ? { text: "#{filter[:label]}: #{value}", drop: [ filter[:name] ] } : nil)
    }
  end

  def prepare_date_range(filter)
    from = filter[:from_value].to_s
    to = filter[:to_value].to_s
    text = date_chip_text(from, to)
    {
      key: filter[:key] || filter[:from_name],
      type: :date_range,
      label: filter[:label],
      from_name: filter[:from_name],
      to_name: filter[:to_name],
      from_value: from,
      to_value: to,
      summary: text.presence || t("toolbar.not_set"),
      param_names: [filter[:from_name], filter[:to_name]],
      chip: (text ? { text: "#{filter[:label]}: #{text}", drop: [filter[:from_name], filter[:to_name]] } : nil)
    }
  end

  def prepare_amount_range(filter)
    min = filter[:min_value].to_s
    max = filter[:max_value].to_s
    text = amount_chip_text(min, max)
    {
      key: filter[:key] || filter[:min_name],
      type: :amount_range,
      label: filter[:label],
      min_name: filter[:min_name],
      max_name: filter[:max_name],
      min_value: min,
      max_value: max,
      summary: text.presence || t("toolbar.not_set"),
      param_names: [filter[:min_name], filter[:max_name]],
      chip: (text ? { text: "#{filter[:label]}: #{text}", drop: [filter[:min_name], filter[:max_name]] } : nil)
    }
  end

  def prepare_boolean(filter)
    checked = filter[:value].to_s == filter[:checked_value].to_s && filter[:value].present?
    {
      key: filter[:key] || filter[:name],
      type: :boolean,
      name: filter[:name],
      label: filter[:label],
      option_label: filter[:option_label],
      checked_value: filter[:checked_value],
      checked: checked,
      summary: checked ? filter[:option_label] : t("toolbar.off"),
      param_names: [filter[:name]],
      chip: (checked ? { text: filter[:option_label], drop: [filter[:name]] } : nil)
    }
  end

  def date_chip_text(from, to)
    from_text = toolbar_date(from)
    to_text = toolbar_date(to)
    return if from_text.blank? && to_text.blank?
    return from_text if to_text.blank?
    return to_text if from_text.blank?

    "#{from_text} - #{to_text}"
  end

  def amount_chip_text(min, max)
    min_text = toolbar_amount(min)
    max_text = toolbar_amount(max)
    return if min_text.blank? && max_text.blank?
    return min_text if max_text.blank?
    return max_text if min_text.blank?

    "#{min_text} - #{max_text}"
  end

  def toolbar_date(value)
    return if value.blank?

    Date.iso8601(value).strftime("%d/%m/%Y")
  rescue Date::Error
    value
  end

  def toolbar_amount(value)
    digits = value.to_s.gsub(/\D/, "")
    return if digits.blank?

    number_with_delimiter(digits.to_i, delimiter: ".")
  end
end
