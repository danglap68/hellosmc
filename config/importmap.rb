# Pin npm packages by running ./bin/importmap

pin "application"
pin "table_csv"
pin "jsqr", to: "jsqr.js", preload: false
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
