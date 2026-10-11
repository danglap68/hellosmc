require "rails_helper"

RSpec.describe Workbook::GoogleSheetClient do
  let(:service) { double("SheetsService") }
  let(:client) { described_class.new(spreadsheet_id: "sheet-id", credentials_io: StringIO.new("{}")) }

  before do
    allow(Google::Apis::SheetsV4::SheetsService).to receive(:new).and_return(service)
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(double("creds"))
    allow(service).to receive(:authorization=)
  end

  describe "#titles" do
    it "returns the sheet titles" do
      sheet = double(properties: double(title: "MB"))
      allow(service).to receive(:get_spreadsheet).with("sheet-id", fields: "sheets.properties.title")
        .and_return(double(sheets: [ sheet ]))
      expect(client.titles).to eq([ "MB" ])
    end
  end

  describe "#values" do
    it "reads unformatted values by default" do
      expect(service).to receive(:get_spreadsheet_values)
        .with("sheet-id", "'MB'!A1:A5", value_render_option: "UNFORMATTED_VALUE")
        .and_return(double(values: [ [ 1 ], [ 2 ] ]))
      expect(client.values("MB", "A1:A5")).to eq([ [ 1 ], [ 2 ] ])
    end
  end

  describe "#update" do
    it "updates with USER_ENTERED" do
      expect(service).to receive(:update_spreadsheet_value)
        .with("sheet-id", "'MB'!A2:K2", instance_of(Google::Apis::SheetsV4::ValueRange),
              value_input_option: "USER_ENTERED")
      client.update("MB", "A2:K2", [ [ 1, 2 ] ])
    end
  end

  describe "#batch_update_values" do
    it "sends every update in a single values.batchUpdate" do
      expect(service).to receive(:batch_update_values)
        .with("sheet-id", instance_of(Google::Apis::SheetsV4::BatchUpdateValuesRequest))
      client.batch_update_values([
        { sheet: "MB", range: "A2:K2", rows: [ [ 1 ] ] },
        { sheet: "R&D Report", range: "H23:H23", rows: [ [ 586_000 ] ] }
      ])
    end
  end

  describe "#duplicate_sheet" do
    it "duplicates the source sheet by id" do
      source = double(properties: double(title: "DS MB T10", sheet_id: 42))
      allow(service).to receive(:get_spreadsheet).with("sheet-id", fields: "sheets.properties")
        .and_return(double(sheets: [ source ]))
      expect(service).to receive(:batch_update_spreadsheet)
        .with("sheet-id", instance_of(Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest))
      client.duplicate_sheet(source_title: "DS MB T10", dest_title: "DS MB T11")
    end

    it "raises when the source sheet is missing" do
      allow(service).to receive(:get_spreadsheet).with("sheet-id", fields: "sheets.properties")
        .and_return(double(sheets: []))
      expect { client.duplicate_sheet(source_title: "DS MB T10", dest_title: "DS MB T11") }
        .to raise_error(ArgumentError, /missing sheet/)
    end
  end

  describe "#rename_sheet / #delete_sheet / #ensure_rows" do
    let(:sheet) { double(properties: double(title: "MB", sheet_id: 7, grid_properties: double(row_count: 1000))) }

    before do
      allow(service).to receive(:get_spreadsheet).with("sheet-id", fields: "sheets.properties")
        .and_return(double(sheets: [ sheet ]))
    end

    it "renames by sheet id" do
      expect(service).to receive(:batch_update_spreadsheet).with("sheet-id", instance_of(Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest))
      client.rename_sheet(from: "MB", to: "MB 2")
    end

    it "deletes by sheet id" do
      expect(service).to receive(:batch_update_spreadsheet).with("sheet-id", instance_of(Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest))
      client.delete_sheet("MB")
    end

    it "does nothing when the grid already has enough rows" do
      expect(service).not_to receive(:batch_update_spreadsheet)
      client.ensure_rows("MB", 1000)
    end

    it "appends rows when the grid is too small" do
      expect(service).to receive(:batch_update_spreadsheet).with("sheet-id", instance_of(Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest))
      client.ensure_rows("MB", 1001)
    end
  end

  describe "#insert_columns" do
    let(:properties) do
      Google::Apis::SheetsV4::SheetProperties.new(
        sheet_id: 77, title: "thu chi 1010",
        grid_properties: Google::Apis::SheetsV4::GridProperties.new(row_count: 100, column_count: 18)
      )
    end

    before do
      allow(service).to receive(:get_spreadsheet)
        .and_return(Google::Apis::SheetsV4::Spreadsheet.new(sheets: [ Google::Apis::SheetsV4::Sheet.new(properties: properties) ]))
    end

    it "shifts only the block rows to the right and copies the left column's format" do
      requests = []
      allow(service).to receive(:batch_update_spreadsheet) { |_id, request| requests.concat(request.requests) }

      client.insert_columns("thu chi 1010", col: 6, end_row: 52)

      insert = requests.first.insert_range
      expect(insert.shift_dimension).to eq("COLUMNS")
      expect(insert.range).to have_attributes(sheet_id: 77, start_row_index: 0, end_row_index: 52,
                                              start_column_index: 6, end_column_index: 7)
      copy = requests.last.copy_paste
      expect(copy.paste_type).to eq("PASTE_FORMAT")
      expect(copy.source.start_column_index).to eq(5)
    end

    it "adds columns first when the grid is too narrow" do
      requests = []
      allow(service).to receive(:batch_update_spreadsheet) { |_id, request| requests.concat(request.requests) }

      client.insert_columns("thu chi 1010", col: 6, end_row: 52, min_cols: 21)

      expect(requests.first.append_dimension).to have_attributes(dimension: "COLUMNS", length: 3)
    end
  end

  describe "sheet metadata" do
    let(:props) { Google::Apis::SheetsV4::SheetProperties }

    it "is fetched once for several lookups and again after a structural change" do
      sheets = [ double(properties: props.new(sheet_id: 1, title: "MB", grid_properties: Google::Apis::SheetsV4::GridProperties.new(row_count: 10, column_count: 12))) ]
      expect(service).to receive(:get_spreadsheet).with("sheet-id", fields: "sheets.properties")
        .and_return(double(sheets: sheets)).twice
      allow(service).to receive(:batch_update_spreadsheet)

      client.ensure_rows("MB", 5)
      client.ensure_rows("MB", 50)
      client.ensure_rows("MB", 60)
    end
  end
end
