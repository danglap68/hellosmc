require "pagy/extras/bootstrap"
require "pagy/extras/overflow"
require "pagy/extras/i18n"

Pagy::DEFAULT[:limit] = 25
Pagy::DEFAULT[:overflow] = :last_page

Rails.application.config.i18n.load_path += [ Pagy.root.join("locales", "vi.yml").to_s ]
