require "google/apis/sheets_v4"
require "googleauth"
require "stringio"

module Workbook
  class GoogleSheetClient
    SCOPE = "https://www.googleapis.com/auth/spreadsheets"

    def initialize(spreadsheet_id:, credentials_io: nil)
      @spreadsheet_id = spreadsheet_id
      @service = Google::Apis::SheetsV4::SheetsService.new
      @service.authorization = credentials(credentials_io)
    end

    def titles
      @titles ||= @service.get_spreadsheet(@spreadsheet_id, fields: "sheets.properties.title")
        .sheets.map { |sheet| sheet.properties.title }
    end

    def values(sheet, range, value_render_option: "UNFORMATTED_VALUE")
      Array(@service.get_spreadsheet_values(
        @spreadsheet_id, "'#{sheet}'!#{range}", value_render_option: value_render_option
      ).values)
    end

    def update(sheet, range, rows)
      @service.update_spreadsheet_value(
        @spreadsheet_id,
        "'#{sheet}'!#{range}",
        Google::Apis::SheetsV4::ValueRange.new(values: rows),
        value_input_option: "USER_ENTERED"
      )
    end

    def batch_update_values(updates)
      data = updates.map do |update|
        Google::Apis::SheetsV4::ValueRange.new(
          range: "'#{update[:sheet]}'!#{update[:range]}",
          values: update[:rows]
        )
      end
      request = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(
        value_input_option: "USER_ENTERED",
        data: data
      )
      @service.batch_update_values(@spreadsheet_id, request)
    end

    def duplicate_sheet(source_title:, dest_title:)
      spreadsheet = @service.get_spreadsheet(@spreadsheet_id, fields: "sheets.properties")
      source = spreadsheet.sheets.find { |sheet| sheet.properties.title == source_title }
      raise ArgumentError, "missing sheet #{source_title}" unless source

      request = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(
        requests: [
          { duplicate_sheet: { source_sheet_id: source.properties.sheet_id, new_sheet_name: dest_title } }
        ]
      )
      @service.batch_update_spreadsheet(@spreadsheet_id, request)
      @titles = nil
    end

    private

    def credentials(credentials_io)
      io = credentials_io || credentials_from_env
      raise ArgumentError, "Google Sheets credentials are missing" unless io

      Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: io, scope: SCOPE)
    end

    def credentials_from_env
      if AppConfig.google_sheets_credentials_json.present?
        StringIO.new(AppConfig.google_sheets_credentials_json)
      elsif AppConfig.google_sheets_credentials_path.present?
        File.open(AppConfig.google_sheets_credentials_path)
      end
    end
  end
end
