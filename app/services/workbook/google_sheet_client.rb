require "google/apis/sheets_v4"
require "googleauth"
require "stringio"

module Workbook
  class GoogleSheetClient
    SCOPE = "https://www.googleapis.com/auth/spreadsheets"
    GROW_BY = 200

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

    # Note: Sheets skips null on write. Use "" to clear a cell.
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
      source = sheet_properties(source_title)
      structural_update(duplicate_sheet: { source_sheet_id: source.sheet_id, new_sheet_name: dest_title })
    end

    def rename_sheet(from:, to:)
      sheet = sheet_properties(from)
      structural_update(update_sheet_properties: { properties: { sheet_id: sheet.sheet_id, title: to }, fields: "title" })
    end

    def delete_sheet(title)
      sheet = sheet_properties(title)
      structural_update(delete_sheet: { sheet_id: sheet.sheet_id })
    end

    # values.update does not grow the grid (writing past the last row is a 400
    # "exceeds grid limits"), so add rows before writing there.
    def ensure_rows(title, min_rows)
      sheet = sheet_properties(title)
      current = sheet.grid_properties&.row_count.to_i
      return if current >= min_rows

      structural_update(append_dimension: {
        sheet_id: sheet.sheet_id, dimension: "ROWS", length: [ min_rows - current, GROW_BY ].max
      })
    end

    private

    def sheet_properties(title)
      spreadsheet = @service.get_spreadsheet(@spreadsheet_id, fields: "sheets.properties")
      properties = spreadsheet.sheets.map(&:properties).find { |props| props.title == title }
      raise ArgumentError, "missing sheet #{title}" unless properties

      properties
    end

    def structural_update(request)
      @service.batch_update_spreadsheet(
        @spreadsheet_id,
        Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: [ request ])
      )
      @titles = nil
    end

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
