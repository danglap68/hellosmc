# Admin form for the technical tuning (AppConfig::TUNING). A filled field is
# stored and wins over the environment variable; a blank field removes the
# stored value so the environment variable or the default applies again.
# Every change is audited.
class TuningForm
  include ActiveModel::Model

  attr_reader :values

  def initialize(params = nil)
    stored = current_values
    @values = AppConfig::TUNING.keys.index_with { |key| AppConfig.stored_tuning(key, stored).to_s }
    params&.each { |key, value| @values[key.to_s] = value.to_s.strip if @values.key?(key.to_s) }
  end

  def [](key)
    @values[key.to_s]
  end
  alias_method :read_attribute_for_validation, :[]

  def self.human_attribute_name(attribute, options = {})
    I18n.t("settings.keys.#{attribute}", default: attribute.to_s.humanize)
  end

  def self.model_name
    ActiveModel::Name.new(self, nil, "Tuning")
  end

  validate :values_valid

  # Returns true when saved (or nothing changed).
  def save(actor:)
    return false unless valid?

    stored = current_values
    changes = AppConfig::TUNING.keys.each_with_object({}) do |key, memo|
      before = AppConfig.stored_tuning(key, stored)
      after = @values[key].presence
      memo[key] = [ before, after ] if before != after
    end
    return true if changes.empty?

    AppSetting.transaction do
      changes.each do |key, (_before, after)|
        if after
          AppSetting.find_or_initialize_by(key: key).update!(value: after, updated_by: actor)
        else
          AppSetting.where(key: [ key, AppConfig::TUNING[key][:legacy] ].compact).delete_all
        end
      end
      AuditLogger.log!(actor: actor, action: "settings.tuning_updated",
                       before_data: changes.transform_values(&:first), after_data: changes.transform_values(&:last))
    end
    AppSetting.reset_cache!
    true
  end

  private

  def current_values
    AppSetting.pluck(:key, :value).to_h
  end

  def values_valid
    AppConfig::TUNING.each do |key, spec|
      raw = @values[key]
      next if raw.blank?

      value = AppConfig.cast_tuning(spec, raw)
      if value.nil?
        errors.add(key, spec[:options] ? :inclusion : :invalid)
      elsif spec[:range] && !spec[:range].cover?(value)
        errors.add(key, :out_of_range, min: spec[:range].min, max: spec[:range].max)
      end
    end
  end
end
