module Workbook
  # Checks the agents' headers in this month's DS MB tab against the database
  # without a bill: the same lookup and the same rules as the writer
  # (DsHeaderMatcher, DsHeaderChange). Runs from the HKD page and from rake.
  #
  #   ok         the header text matches ds_header
  #   renamed    same person, new text: ds_header updated
  #   switched   another existing dealer: the agent row now belongs to that dealer
  #   unmatched  a name nobody has, an unclear name, or a switch while the setting is off: nothing changed
  #   missing    the HKD's cell or the agent's column is not in the tab
  #
  # Bills already approved but not yet in the sheet are moved to the new dealer
  # when the writer reaches them (HelloSmcWriter), not here.
  class DsHeaderSync
    STATUSES = %i[ok renamed switched unmatched missing].freeze

    Row = Data.define(:link, :status, :header)
    Report = Data.define(:sheet, :rows) do
      def counts
        STATUSES.index_with { |status| rows.count { |row| row.status == status } }
      end
    end

    class SheetMissing < StandardError; end

    def self.call(merchants: nil, client: nil, spreadsheet_id: AppConfig.hello_smc_spreadsheet_id, apply: true,
                  source: "sync", now: Time.current)
      new(merchants:, client:, spreadsheet_id:, apply:, source:, now:).call
    end

    def initialize(merchants:, client:, spreadsheet_id:, apply:, source:, now:)
      @merchants = merchants
      @client = client
      @spreadsheet_id = spreadsheet_id
      @apply = apply
      @source = source
      @now = now
    end

    def call
      raise HelloSmcWriter::ConfigurationError, "hello_smc_spreadsheet_id is not configured" if @spreadsheet_id.blank?

      client = @client || GoogleSheetClient.new(spreadsheet_id: @spreadsheet_id)
      SheetLock.with(@spreadsheet_id) do
        sheet = "#{HelloSmcWriter::DS_PREFIX}#{@now.in_time_zone.month}"
        raise SheetMissing, sheet unless client.titles.include?(sheet)

        grid = client.values(sheet, HelloSmcWriter::DS_READ_RANGE)
        Report.new(sheet: sheet, rows: links.map { |link| check(link, grid, sheet) })
      end
    end

    private

    def links
      scope = MerchantDealer.active.includes(:dealer, :merchant).order(:merchant_id, :tid_key)
      scope = scope.where(merchant: @merchants) if @merchants
      scope
    end

    def check(link, grid, sheet)
      location = DsHeaderMatcher.locate(grid: grid, link: link, last_col: HelloSmcWriter::DS_LAST_COL)
      return Row.new(link:, status: :missing, header: nil) unless location&.col

      change = location.change
      return Row.new(link:, status: :ok, header: link.ds_header) unless change

      Row.new(link:, status: apply(link, change, sheet), header: change.header)
    end

    def apply(link, change, sheet)
      case change.kind
      when :same, :rename
        DsHeaderChange.rename!(link:, header: change.header, sheet:, source: @source) if @apply
        :renamed
      when :switch
        return :unmatched unless AppConfig.ds_header_auto_switch?
        return :switched unless @apply

        switched = DsHeaderChange.switch!(link:, dealer: change.dealer, header: change.header, sheet:, source: @source)
        switched ? :switched : :unmatched
      else
        :unmatched
      end
    end
  end
end
