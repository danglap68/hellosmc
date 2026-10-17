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

    # index: position of the copy among the tabs (0-based); nil puts it last.
    def duplicate_sheet(source_title:, dest_title:, index: nil)
      source = sheet_properties(source_title)
      request = { source_sheet_id: source.sheet_id, new_sheet_name: dest_title }
      request[:insert_sheet_index] = index if index
      structural_update(duplicate_sheet: request)
    end

    # Removes the note of each cell ([row, col], 0-based) in one request.
    def clear_notes(title, cells)
      return if cells.empty?

      id = sheet_properties(title).sheet_id
      structural_updates(cells.map do |row, col|
        Google::Apis::SheetsV4::Request.new(
          repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
            range: Google::Apis::SheetsV4::GridRange.new(sheet_id: id, start_row_index: row, end_row_index: row + 1,
                                                         start_column_index: col, end_column_index: col + 1),
            cell: Google::Apis::SheetsV4::CellData.new(note: ""), fields: "note"
          )
        )
      end)
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

    # Inserts one blank column at col (0-based) for rows 0...end_row only,
    # shifting the cells to its right; rows below (a manual accounting area)
    # keep their columns. The left neighbour's format is copied. Formulas that
    # point at the moved cells are adjusted by Sheets itself.
    def insert_columns(title, col:, end_row:, min_cols: nil)
      sheet = sheet_properties(title)
      id = sheet.sheet_id
      current = sheet.grid_properties&.column_count.to_i

      requests = []
      if min_cols && current < min_cols
        requests << Google::Apis::SheetsV4::Request.new(
          append_dimension: Google::Apis::SheetsV4::AppendDimensionRequest.new(
            sheet_id: id, dimension: "COLUMNS", length: min_cols - current
          )
        )
      end

      range = Google::Apis::SheetsV4::GridRange.new(
        sheet_id: id, start_row_index: 0, end_row_index: end_row,
        start_column_index: col, end_column_index: col + 1
      )
      requests << Google::Apis::SheetsV4::Request.new(
        insert_range: Google::Apis::SheetsV4::InsertRangeRequest.new(range: range, shift_dimension: "COLUMNS")
      )

      unless col.zero?
        source = Google::Apis::SheetsV4::GridRange.new(
          sheet_id: id, start_row_index: 0, end_row_index: end_row,
          start_column_index: col - 1, end_column_index: col
        )
        requests << Google::Apis::SheetsV4::Request.new(
          copy_paste: Google::Apis::SheetsV4::CopyPasteRequest.new(
            source: source, destination: range, paste_type: "PASTE_FORMAT"
          )
        )
      end

      structural_updates(requests)
    end

    # Inserts one whole sheet row at row (0-based), formatted like the row above,
    # and writes value + note into (row, col) in the same request: Sheets applies
    # the requests of one batchUpdate in order and all-or-nothing. References to
    # the rows below move with them, so a SUM over a range that contains the new
    # row grows by one.
    def insert_row_with_value(title, row:, col:, value:, note:)
      id = sheet_properties(title).sheet_id
      requests = [
        Google::Apis::SheetsV4::Request.new(
          insert_dimension: Google::Apis::SheetsV4::InsertDimensionRequest.new(
            range: Google::Apis::SheetsV4::DimensionRange.new(
              sheet_id: id, dimension: "ROWS", start_index: row, end_index: row + 1
            ),
            inherit_from_before: row.positive?
          )
        ),
        Google::Apis::SheetsV4::Request.new(
          update_cells: Google::Apis::SheetsV4::UpdateCellsRequest.new(
            start: Google::Apis::SheetsV4::GridCoordinate.new(sheet_id: id, row_index: row, column_index: col),
            rows: [
              Google::Apis::SheetsV4::RowData.new(values: [
                Google::Apis::SheetsV4::CellData.new(
                  user_entered_value: Google::Apis::SheetsV4::ExtendedValue.new(number_value: value.to_f),
                  note: note
                )
              ])
            ],
            fields: "userEnteredValue,note"
          )
        )
      ]
      structural_updates(requests)
    end

    # Inserts one blank sheet row at row (0-based), formatted like the row above.
    # References to the rows below move with them.
    def insert_row(title, row:)
      structural_update(insert_dimension: {
        range: { sheet_id: sheet_properties(title).sheet_id, dimension: "ROWS", start_index: row, end_index: row + 1 },
        inherit_from_before: row.positive?
      })
    end

    # Cell notes of a range as a 2-D array (nil where a cell has none), the same
    # shape as #values.
    def notes(title, range)
      spreadsheet = @service.get_spreadsheet(
        @spreadsheet_id, ranges: [ "'#{title}'!#{range}" ], include_grid_data: true,
        fields: "sheets.data.rowData.values.note"
      )
      rows = spreadsheet.sheets&.first&.data&.first&.row_data
      Array(rows).map { |row_data| Array(row_data&.values).map(&:note) }
    end

    private

    # One metadata call serves every lookup of a write (grow rows, insert
    # columns, duplicate/rename); it is dropped after any structural change.
    # Sheets API reads are rate limited per minute, so calls are not free.
    def sheet_properties(title)
      @sheet_properties ||= @service.get_spreadsheet(@spreadsheet_id, fields: "sheets.properties")
        .sheets.map(&:properties)
      properties = @sheet_properties.find { |props| props.title == title }
      raise ArgumentError, "missing sheet #{title}" unless properties

      properties
    end

    def structural_update(request)
      structural_updates([ request ])
    end

    def structural_updates(requests)
      @service.batch_update_spreadsheet(
        @spreadsheet_id,
        Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests)
      )
      @titles = nil
      @sheet_properties = nil
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
