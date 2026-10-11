module FeeRules
  # Idempotent seed of the real fee rules (as configured in the admin on
  # 2026-10-11). Each rule is identified by metadata["seed_key"]: a rule that
  # already exists is left untouched, so rates edited later in the admin are
  # never overwritten by a re-run. Merchants are looked up by name and must
  # exist (Workbook::Seed creates them).
  class Seed
    SYSTEM_START = Time.utc(2026, 9, 30, 17) # 2026-10-01 00:00 +07
    HKD_START = Time.utc(2026, 10, 10, 17)   # 2026-10-11 00:00 +07

    RULES = [
      { key: "system_default", note: "Mặc định hệ thống", base: "0.0121", dealer: "0.014",
        from: SYSTEM_START },
      { key: "card_mb_napas", note: "Thẻ MB, Napas", base: "0.0088", dealer: "0.012",
        from: SYSTEM_START, card_types: %w[mb napas] },
      { key: "hkd_thien_kim_cherry_gat", note: "HKD Thiên Kim GV, Cherry Coffee, Gat Tan Day Coffe",
        base: "0.0121", dealer: "0.014", from: SYSTEM_START,
        merchants: [ "001_ HỘ KINH DOANH THIÊN KIM GV", "Cherry Coffee", "Gat Tan Day Coffe" ] },
      { key: "hkd_as_cafe_96_milo", note: "HKD AS CAFE-CAFE 96, HKD AS CAFE-CAFE MILO",
        base: "0.0117", dealer: "0.0117", from: HKD_START,
        merchants: [ "HKD AS CAFE-CAFE 96", "HKD AS CAFE-CAFE MILO" ] },
      { key: "hkd_as_cafe_nct", note: "HKD AS CAFE, HKD NCT, HKD NCT MBV",
        base: "0.0115", dealer: "0.014", from: HKD_START,
        merchants: [ "HKD AS CAFE", "HKD NCT", "HKD NCT MBV" ] }
    ].freeze

    def self.call = new.call

    def call
      ActiveRecord::Base.transaction { RULES.each { |attrs| seed(attrs) } }
      FeeRule.count
    end

    private

    def seed(attrs)
      return if FeeRule.where("metadata ->> 'seed_key' = ?", attrs[:key]).exists?

      FeeRule.create!(
        base_fee_rate: BigDecimal(attrs[:base]),
        dealer_rate: BigDecimal(attrs[:dealer]),
        effective_from: attrs[:from],
        priority: 100,
        merchants: attrs.fetch(:merchants, []).map { |name| Merchant.find_by!(name: name) },
        card_types: attrs.fetch(:card_types, []).map { |key| CardType.find_by!(key: key) },
        metadata: { "seed_key" => attrs[:key], "note" => attrs[:note] }
      )
    end
  end
end
