# Transfer codes ("TK01") move from config/remitter_transfer_codes.json to the
# agent rows of each HKD (merchant_dealers.transfer_code), so they can be
# changed on the HKD page. Each code names one HKD + one TID, which is exactly
# one row. The table below is the former JSON, copied over once.
class AddTransferCodeToMerchantDealers < ActiveRecord::Migration[8.1]
  # code => [ HKD code, TID ]
  CODES = {
    "TK01" => [ "001", "tid1" ],
    "TK02" => [ "001", "tid2" ],
    "TK03" => [ "001", "tid3" ],
    "GT01" => [ "GTD001", "tid1" ],
    "GT02" => [ "GTD001", "tid2" ],
    "GT03" => [ "GTD001", "tid3" ],
    "CH01" => [ "CHERRY001", "tid1" ],
    "CH02" => [ "CHERRY001", "tid2" ],
    "CH03" => [ "CHERRY001", "tid3" ],
    "ML127" => [ "MILO001", "tid127" ],
    "ML128" => [ "MILO001", "tid128" ],
    "ML129" => [ "MILO001", "tid129" ],
    "CF01" => [ "AS96001", "tid1" ],
    "CF02" => [ "AS96001", "tid2" ],
    "AS01" => [ "ASCAFE001", "tid1" ],
    "AS02" => [ "ASCAFE001", "tid2" ],
    "AS03" => [ "ASCAFE001", "tid3" ],
    "NC01" => [ "NCT001", "tid1" ],
    "NC02" => [ "NCT001", "tid2" ],
    "NC03" => [ "NCT001", "tid3" ],
    "NM01" => [ "NCTMBV001", "tid1" ],
    "NM02" => [ "NCTMBV001", "tid2" ],
    "NM03" => [ "NCTMBV001", "tid3" ]
  }.freeze
  # HKDs that may still carry the older code (Workbook::Seed match_code).
  OLDER_HKD_CODES = { "CHERRY001" => "002 CHERRY COFFE", "AS96001" => "099" }.freeze

  def up
    add_column :merchant_dealers, :transfer_code, :string
    add_index :merchant_dealers, :transfer_code, unique: true, where: "transfer_code IS NOT NULL",
              name: "index_merchant_dealers_on_transfer_code"

    CODES.each do |code, (hkd, tid)|
      hkd_codes = [ hkd, OLDER_HKD_CODES[hkd] ].compact.map(&:upcase)
      execute sanitize(<<~SQL, code, tid, hkd_codes)
        UPDATE merchant_dealers SET transfer_code = ?
        WHERE transfer_code IS NULL AND active AND tid_key = ?
          AND merchant_id IN (SELECT id FROM merchants WHERE UPPER(code) IN (?))
          AND NOT EXISTS (SELECT 1 FROM merchant_dealers other WHERE other.transfer_code = ?)
      SQL
    end
  end

  def down
    remove_index :merchant_dealers, name: "index_merchant_dealers_on_transfer_code"
    remove_column :merchant_dealers, :transfer_code
  end

  private

  # NOT EXISTS needs the code again: bind it twice.
  def sanitize(sql, code, tid, hkd_codes)
    ActiveRecord::Base.sanitize_sql_array([ sql, code, tid, hkd_codes, code ])
  end
end
