module Workbook
  # Admin-side setup of the Google Sheet the transactions are written to: the
  # sheet is opened with the server's Google account before its ID is stored,
  # so a wrong ID or a sheet that was not shared fails here instead of on the
  # next bill. Mirrors Telegram::Connection for the bot token.
  module Connection
    class Error < StandardError; end

    KEY = "hello_smc_spreadsheet_id".freeze
    ID_PATTERN = /\A[A-Za-z0-9_-]{20,}\z/
    URL_PATTERN = %r{/spreadsheets/d/([A-Za-z0-9_-]+)}

    Saved = Data.define(:spreadsheet_id, :tab_count, :checked)

    module_function

    # The ID from a pasted ID or from the sheet's address in the browser.
    def parse_id(input)
      text = input.to_s.strip
      text = text[URL_PATTERN, 1] || text
      text if text.match?(ID_PATTERN)
    end

    # client: a block-less object answering #titles (a stand-in in tests).
    def save_spreadsheet!(input, actor:, client: nil)
      id = parse_id(input)
      raise Error, I18n.t("settings.spreadsheet.errors.invalid") unless id

      checked = AppConfig.google_sheets_credentials_path.present? || AppConfig.google_sheets_credentials_json.present? || client
      titles = checked ? open_sheet!(id, client) : []

      before = AppConfig.hello_smc_spreadsheet_id
      AppSetting.transaction do
        AppSetting.find_or_initialize_by(key: KEY).update!(value: id, updated_by: actor)
        AuditLogger.log!(actor: actor, action: "settings.spreadsheet_updated",
                         before_data: { KEY => before }, after_data: { KEY => id })
      end
      Saved.new(spreadsheet_id: id, tab_count: titles.size, checked: checked.present?)
    end

    def open_sheet!(id, client)
      (client || Workbook::GoogleSheetClient.new(spreadsheet_id: id)).titles
    rescue StandardError => e
      raise Error, I18n.t("settings.spreadsheet.errors.cannot_open", error: e.message.to_s.truncate(200))
    end

    def url(id)
      "https://docs.google.com/spreadsheets/d/#{id}"
    end
  end
end
