module Workbook
  # Idempotent seed for remitters and merchant_dealers, matching the DS MB T10
  # layout documented in docs/SPEC_HELLO_SMC_WORKBOOK.md §4.2 and §4.3.
  module Seed
    REMITTERS = [
      { name: "Lập", excel_key: "LẬP" },
      { name: "Kim", excel_key: "KIM" },
      { name: "An", excel_key: "AN" },
      { name: "Yến", excel_key: "YẾN" },
      { name: "Cô Tuyết", excel_key: "CÔ TUYẾT" }
    ].freeze

    # Each HKD block in DS MB. `code` is the stable app key; `anchor` is the
    # exact HKD header cell in the DS MB sheet.
    HKD = [
      { code: "001", name: "001_ HỘ KINH DOANH THIÊN KIM GV", anchor: "Thiên Kim GV" },
      { code: "GTD001", name: "Gat Tan Day Coffe", anchor: "Gat Tan Day Coffe" },
      { code: "CHERRY001", name: "Cherry Coffee", anchor: "Cherry Coffee", match_code: "002 CHERRY COFFE 2" },
      { code: "MILO001", name: "HKD AS CAFE-CAFE MILO", anchor: "HKD AS CAFE-CAFE MILO" },
      { code: "AS96001", name: "HKD AS CAFE-CAFE 96", anchor: "HKD AS CAFE-CAFE 96", match_code: "099" },
      { code: "ASCAFE001", name: "HKD AS CAFE", anchor: "HKD AS CAFE" }
    ].freeze

    # Extra receipt-name aliases for common OCR misspellings, keyed by HKD code.
    # "CHERRY COFEE" is how OCR often reads "Cherry Coffee".
    RECEIPT_ALIASES = {
      "CHERRY001" => [ "CHERRY COFEE" ]
    }.freeze

    # [hkd_code, dealer_name, tid_key, tid_label, ds_header, rd_agent_label]
    AGENTS = [
      ["001", "Chương", "tid1", "tid1", "Chương (tid1)", "Chương"],
      ["001", "Sơn", "tid2", "tid2", "Sơn(tid2)", "Sơn"],
      ["001", "Hải", "tid3", "tid3", "Hải (tid3)", "NamHai"],
      ["GTD001", "Cường Duyên", "tid1", "tid1", "Cường Duyên(tid1)", "CườngDuyen"],
      ["GTD001", "Trân", "tid2", "tid2", "Trân(tid2)", "Trân"],
      ["GTD001", "Thọ", "tid3", "tid3", "Thọ(tid3)", "Thọ"],
      ["CHERRY001", "Cường Duyên", "tid2", "tid2", "Cường Duyên(tid2)", "CườngDuyen"],
      ["CHERRY001", "Trân", "tid3", "tid3", "Trân ( tid3)", "Trân"],
      ["CHERRY001", "Nghĩa Nghiệp", "tid1", "tid1", "Nghĩa Nghiệp (tid1)", "Nghĩa"],
      ["MILO001", "Chị Huệ", "tid127", "TID 127", "Chị Huệ (TID 127)", "Chị Huệ"],
      ["MILO001", "Chị Huệ", "tid128", "TID 128", "Chị Huệ (TID 128)", "Chị Huệ"],
      ["MILO001", "Chị Huệ", "tid129", "TID 129", "Chị Huệ (TID 129)", "Chị Huệ"],
      ["AS96001", "PHÙNG CUỜNG", "tid1", "TID 1", "PHÙNG CUỜNG(TID 1)", "PCuong"],
      ["AS96001", "Anh Hiếu", "tid2", "TID 2", "Anh Hiếu (TID 2)", "HiêuSG"],
      ["ASCAFE001", "Anh Hải", "tid1", "tid 1", "Anh Hải (tid 1)", "Anh Hải"],
      ["ASCAFE001", "Anh Hùng", "tid2", "tid 2", "Anh Hùng (tid 2)", "Hùng"],
      ["ASCAFE001", "Chị Hồng", "tid3", "tid 3", "Chị Hồng (tid 3)", "Hồng"]
    ].freeze

    module_function

    def call
      seed_remitters
      seed_merchant_dealers
    end

    def seed_remitters
      REMITTERS.each do |attrs|
        remitter = Remitter.find_or_initialize_by(excel_key: attrs[:excel_key])
        remitter.assign_attributes(name: attrs[:name])
        remitter.save!
      end
    end

    def seed_merchant_dealers
      merchants = HKD.to_h { |attrs| [ attrs[:code], find_or_create_merchant(attrs) ] }

      AGENTS.each do |(code, dealer_name, tid_key, tid_label, ds_header, rd_label)|
        merchant = merchants.fetch(code)
        dealer = find_or_create_dealer(dealer_name)
        merchant.merchant_dealers.find_or_create_by!(dealer: dealer, tid_key: tid_key) do |link|
          link.tid_label = tid_label
          link.ds_sheet_anchor = merchant_anchor(code)
          link.ds_header = ds_header
          link.rd_agent_label = rd_label
          link.active = true
        end
      end
    end

    def find_or_create_merchant(attrs)
      merchant = Merchant.find_by(code: attrs[:match_code]) || Merchant.find_or_initialize_by(code: attrs[:code])
      merchant.assign_attributes(name: attrs[:name]) if merchant.new_record?
      merchant.save!
      merchant.merchant_aliases.find_or_create_by!(alias_type: "receipt_name", alias: attrs[:anchor])
      RECEIPT_ALIASES.fetch(attrs[:code], []).each do |alias_name|
        merchant.merchant_aliases.find_or_create_by!(alias_type: "receipt_name", alias: alias_name)
      end
      merchant
    end

    def find_or_create_dealer(name)
      Dealer.find_or_create_by!(name: name) do |dealer|
        dealer.code = unique_dealer_code(name)
      end
    end

    def unique_dealer_code(name)
      base = VietnameseText.normalize_identifier(name)
      return base if base.present? && Dealer.where(code: base).where.not(name: name).none?

      suffix = 2
      suffix += 1 while Dealer.exists?(code: "#{base}#{suffix}")
      "#{base}#{suffix}"
    end

    def merchant_anchor(code)
      HKD.find { |attrs| attrs[:code] == code }.fetch(:anchor)
    end
  end
end
