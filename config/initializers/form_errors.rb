# Tabler marks invalid fields itself; do not wrap them in div.field_with_errors.
ActionView::Base.field_error_proc = proc { |html_tag, _instance| html_tag }
