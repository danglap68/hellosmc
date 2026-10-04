# Admin form for AppSetting. Percent settings are edited as percentages
# ("92") and stored as rates ("0.92"). Every change is audited.
class SettingsForm
  include ActiveModel::Model

  attr_reader :values

  def initialize(params = nil)
    @values = AppSetting::DEFINITIONS.to_h do |key, definition|
      value = case key
      when "primary_vision_model" then AppConfig.primary_vision_model
      when "max_ocr_attempts" then AppConfig.max_ocr_attempts
      else AppSetting.get(key)
      end
      [ key, display_value(definition, value) ]
    end
    params&.each { |key, value| @values[key.to_s] = value.to_s if @values.key?(key.to_s) }
  end

  def [](key)
    @values[key.to_s]
  end
  alias_method :read_attribute_for_validation, :[]

  def self.human_attribute_name(attribute, options = {})
    I18n.t("settings.keys.#{attribute}", default: attribute.to_s.humanize)
  end

  def self.model_name
    ActiveModel::Name.new(self, nil, "Settings")
  end

  validate :values_within_bounds
  validate :thresholds_ordered
  validate :provider_has_api_key
  validate :mailer_sender_format

  # Returns true when saved (or nothing changed).
  def save(actor:)
    return false unless valid?

    current = AppSetting.unscoped.pluck(:key, :value).to_h
    changes = AppSetting::DEFINITIONS.each_with_object({}) do |(key, definition), memo|
      before = definition.serialize(current.fetch(key, definition.default))
      after = definition.serialize(stored_value(definition))
      memo[key] = [ before, after ] if before != after
    end
    return true if changes.empty?

    AppSetting.transaction do
      changes.each do |key, (_before, after)|
        AppSetting.find_or_initialize_by(key: key).update!(value: after, updated_by: actor)
      end
      AuditLogger.log!(actor: actor, action: "settings.updated",
                       before_data: changes.transform_values(&:first), after_data: changes.transform_values(&:last))
    end
    true
  end

  private

  def display_value(definition, value)
    case definition.type
    when :percent then Percentage.rate_to_percent_string(value)
    when :boolean then value ? "1" : "0"
    else value.to_s
    end
  end

  # The value to persist, converted back from the form representation.
  def stored_value(definition)
    raw = @values[definition.key]
    definition.type == :percent ? Percentage.percent_to_rate(raw) : raw
  end

  def parsed(definition)
    raw = stored_value(definition)
    return nil if raw.nil?

    definition.cast(definition.serialize(raw))
  rescue ArgumentError, TypeError
    nil
  end

  def values_within_bounds
    AppSetting::DEFINITIONS.each do |key, definition|
      case definition.type
      when :percent, :decimal, :integer
        value = parsed(definition)
        if value.nil?
          errors.add(key, :not_a_number)
        elsif value < BigDecimal(definition.min) || value > BigDecimal(definition.max)
          errors.add(key, :out_of_range, min: display_value(definition, definition.cast(definition.min)),
                                         max: display_value(definition, definition.cast(definition.max)))
        end
      when :select
        errors.add(key, :inclusion) unless definition.options.include?(@values[key])
      when :string
        errors.add(key, :blank) if @values[key].to_s.strip.empty?
      end
    end
  end

  def thresholds_ordered
    auto = parsed(AppSetting::DEFINITIONS["ocr_auto_approve_threshold"])
    review = parsed(AppSetting::DEFINITIONS["ocr_review_threshold"])
    return unless auto && review && review > auto

    errors.add(:ocr_review_threshold, :above_auto_threshold)
  end

  # Only when switching provider, so other settings stay editable before keys are set up.
  def provider_has_api_key
    key = { "openai" => AppConfig.openai_api_key, "gemini" => AppConfig.gemini_api_key }
    provider = @values["vision_provider"]
    return if provider == AppSetting.get("vision_provider")
    return unless key.key?(provider) && key[provider].blank?

    errors.add(:vision_provider, :api_key_missing, env: "#{provider.upcase}_API_KEY")
  end

  def mailer_sender_format
    return if @values["mailer_sender"].to_s.match?(URI::MailTo::EMAIL_REGEXP)

    errors.add(:mailer_sender, :invalid)
  end
end
