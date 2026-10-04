# Renders Tabler-styled fields with label, validation state and hint, so that
# admin forms stay short and consistent.
class TablerFormBuilder < ActionView::Helpers::FormBuilder
  def error_summary
    return "".html_safe if object.nil? || object.errors.empty?

    @template.content_tag(:div, class: "alert alert-danger", role: "alert") do
      @template.safe_join([
        @template.content_tag(:h4, I18n.t("forms.error_summary", count: object.errors.count), class: "alert-title"),
        @template.content_tag(:ul, class: "mb-0") do
          @template.safe_join(object.errors.full_messages.uniq.map { |message| @template.content_tag(:li, message) })
        end
      ])
    end
  end

  def field(attribute, as: :text_field, label: nil, hint: nil, required: false, wrapper: "mb-3", **options)
    options[:class] = control_class(attribute, options[:class] || "form-control")
    wrap(attribute, label: label, hint: hint, required: required, wrapper: wrapper) do
      public_send(as, attribute, options)
    end
  end

  def select_field(attribute, choices, select_options = {}, label: nil, hint: nil, required: false, wrapper: "mb-3", **html_options)
    html_options[:class] = control_class(attribute, html_options[:class] || "form-select")
    wrap(attribute, label: label, hint: hint, required: required, wrapper: wrapper) do
      select(attribute, choices, select_options, html_options)
    end
  end

  def switch_field(attribute, label: nil, hint: nil, wrapper: "mb-3")
    @template.content_tag(:div, class: wrapper) do
      @template.safe_join([
        @template.content_tag(:label, class: "form-check form-switch") do
          @template.safe_join([
            check_box(attribute, class: "form-check-input"),
            @template.content_tag(:span, label || human(attribute), class: "form-check-label")
          ])
        end,
        hint ? @template.content_tag(:small, hint, class: "form-hint") : nil
      ].compact)
    end
  end

  def submit_button(label = nil, **options)
    options[:class] ||= "btn btn-primary"
    @template.button_tag(type: "submit", **options) do
      @template.safe_join([ @template.content_tag(:i, nil, class: "ti ti-device-floppy icon"), label || I18n.t("actions.save") ])
    end
  end

  private

  def wrap(attribute, label:, hint:, required:, wrapper:)
    errors = errors_for(attribute)
    @template.content_tag(:div, class: wrapper) do
      @template.safe_join([
        label(attribute, label || human(attribute), class: [ "form-label", ("required" if required) ].compact.join(" ")),
        yield,
        errors.any? ? @template.content_tag(:div, errors.uniq.to_sentence, class: "invalid-feedback d-block") : nil,
        hint ? @template.content_tag(:small, hint, class: "form-hint") : nil
      ].compact)
    end
  end

  def control_class(attribute, base)
    [ base, ("is-invalid" if errors_for(attribute).any?) ].compact.join(" ")
  end

  def errors_for(attribute)
    return [] unless object.respond_to?(:errors)

    base_attribute = attribute.to_s.delete_suffix("_id").to_sym
    object.errors[attribute] + (base_attribute == attribute ? [] : object.errors[base_attribute])
  end

  def human(attribute)
    object.class.respond_to?(:human_attribute_name) ? object.class.human_attribute_name(attribute) : attribute.to_s.humanize
  end
end
