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
      { code: "CHERRY001", name: "Cherry Coffee", anchor: "Cherry Coffee", match_code: "002 CHERRY COFFE" },
      { code: "MILO001", name: "HKD AS CAFE-CAFE MILO", anchor: "HKD AS CAFE-CAFE MILO" },
      { code: "AS96001", name: "HKD AS CAFE-CAFE 96", anchor: "HKD AS CAFE-CAFE 96", match_code: "099" },
      { code: "ASCAFE001", name: "HKD AS CAFE", anchor: "HKD AS CAFE" },
      { code: "NCT001", name: "HKD NCT", anchor: "HKD NCT" },
      { code: "NCTMBV001", name: "HKD NCT MBV", anchor: "HKD NCT MBV" }
    ].freeze

    # Extra receipt-name aliases for common OCR misspellings/truncations, keyed
    # by HKD code. OCR often drops the trailing branch ("GV") or misspells names.
    RECEIPT_ALIASES = {
      "CHERRY001" => [ "CHERRY COFEE" ],
      "001" => [ "HỘ KINH DOANH THIÊN KIM" ]
    }.freeze

    # [hkd_code, dealer_name, tid_key, tid_label, ds_header, rd_agent_label]
    #
    # rd_agent_label must match the agent's label in the daily "thu chi" tab
    # (name only; the channel such as "(MB+SP)" is ignored). Verified against
    # the 10/10/2026 tab: Chương, Sơn, NamHai, CườngDuyen, Trân, Thọ, Nghĩa,
    # Chị Huệ, PCuong, HiêuSG, Hùng, Hồng, Mến, Nghiệp.
    # TODO(confirm): "Anh Hải" and "Tuân" have no obvious block in the tab
    # (candidates: HảiHN / Tuấn). They are kept as-is, so those agents report
    # rd_agent_missing instead of risking money in the wrong block.
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
      ["ASCAFE001", "Chị Hồng", "tid3", "tid 3", "Chị Hồng (tid 3)", "Hồng"],
      ["NCT001", "Chị Mến", "tid1", "tid1", "CHỊ MẾN (tid 1)", "Mến"],
      ["NCT001", "Anh Hải", "tid2", "tid2", "Anh Hải ( tid 2)", "Anh Hải"],
      ["NCT001", "Nghiệp", "tid3", "tid3", "NGHIỆP (tid 3)", "Nghiệp"],
      ["NCTMBV001", "Sơn", "tid1", "tid1", "SƠN (tid 1)", "Sơn"],
      ["NCTMBV001", "Anh Thọ", "tid2", "tid2", "Anh Thọ (tid 2)", "Thọ"],
      ["NCTMBV001", "Tuân", "tid3", "tid3", "Tuân (tid3)", "Tuân"]
    ].freeze

    # Starting transfer codes of a new install (HKD code, TID => code). Existing
    # installs keep what was set on the HKD page: the seed only fills blanks.
    TRANSFER_CODES = {
      [ "001", "tid1" ] => "TK01",
      [ "001", "tid2" ] => "TK02",
      [ "001", "tid3" ] => "TK03",
      [ "GTD001", "tid1" ] => "GT01",
      [ "GTD001", "tid2" ] => "GT02",
      [ "GTD001", "tid3" ] => "GT03",
      [ "CHERRY001", "tid1" ] => "CH01",
      [ "CHERRY001", "tid2" ] => "CH02",
      [ "CHERRY001", "tid3" ] => "CH03",
      [ "MILO001", "tid127" ] => "ML127",
      [ "MILO001", "tid128" ] => "ML128",
      [ "MILO001", "tid129" ] => "ML129",
      [ "AS96001", "tid1" ] => "CF01",
      [ "AS96001", "tid2" ] => "CF02",
      [ "ASCAFE001", "tid1" ] => "AS01",
      [ "ASCAFE001", "tid2" ] => "AS02",
      [ "ASCAFE001", "tid3" ] => "AS03",
      [ "NCT001", "tid1" ] => "NC01",
      [ "NCT001", "tid2" ] => "NC02",
      [ "NCT001", "tid3" ] => "NC03",
      [ "NCTMBV001", "tid1" ] => "NM01",
      [ "NCTMBV001", "tid2" ] => "NM02",
      [ "NCTMBV001", "tid3" ] => "NM03"
    }.freeze

    module_function

    def call
      seed_remitters
      seed_merchant_dealers
    end

    # Development only: one active Telegram group per agent. Chat ids are demo
    # values; in production groups register themselves when the bot joins.
    def seed_telegram_chats
      dealer_names = AGENTS.map { |(_code, dealer_name, *_rest)| dealer_name }.uniq
      dealer_names.each_with_index do |dealer_name, index|
        chat = TelegramChat.find_or_initialize_by(telegram_chat_id: -1_002_000_000_000 - index)
        chat.name ||= "Bill #{dealer_name}"
        chat.chat_type ||= "supergroup"
        chat.active = true if chat.new_record?
        chat.save!
      end
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
        # The row of this TID changed hands (the DS MB header named another
        # dealer, see Workbook::DsHeaderChange): a second active row for the
        # same TID is not allowed, and the new holder is not the seed's to undo.
        holder = merchant.merchant_dealers.active.find_by(tid_key: tid_key)
        next if holder && holder.dealer.name != dealer_name

        dealer = find_or_create_dealer(dealer_name)
        # Upsert: the seed is the source of truth for these mapping fields, so a
        # re-run corrects labels that drifted from the sheets (e.g. rd labels).
        link = merchant.merchant_dealers.find_or_initialize_by(dealer: dealer, tid_key: tid_key)
        link.assign_attributes(tid_label: tid_label, ds_sheet_anchor: merchant_anchor(code),
                               ds_header: ds_header, rd_agent_label: rd_label)
        link.active = true if link.new_record?
        link.transfer_code ||= TRANSFER_CODES[[ code, tid_key ]]
        link.save!
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
