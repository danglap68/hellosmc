# Idempotent seeds. Safe to run repeatedly.
#
#   SEED_ADMIN_EMAIL=admin@example.com SEED_ADMIN_PASSWORD=... bin/rails db:seed
#
# Sample dealers/merchants/fee rules are created in development only. Fee
# values below are DEMO values; real rates are configured in the admin UI.

[
  { key: "normal", name: "Thẻ thường", aliases: [ "normal", "the thuong" ], position: 0 },
  { key: "mb", name: "MB", aliases: [ "mb" ], position: 10 },
  { key: "napas", name: "Napas", aliases: [ "napas" ], position: 20 }
].each do |attributes|
  card_type = CardType.find_or_initialize_by(key: attributes[:key])
  card_type.assign_attributes(attributes) if card_type.new_record?
  card_type.save!
end
puts "Card types: #{CardType.pluck(:key).join(', ')}"

admin_email = ENV.fetch("SEED_ADMIN_EMAIL", "danglap686868@gmail.com")
unless User.exists?(email: admin_email)
  password = ENV["SEED_ADMIN_PASSWORD"].presence
  if password.nil?
    abort "SEED_ADMIN_PASSWORD is required to create the first admin in production." if Rails.env.production?

    password = SecureRandom.base58(16)
    puts "Generated admin password (development only): #{password}"
  end
  User.create!(email: admin_email, name: "Quản trị viên", role: "admin", active: true,
               password: password, password_confirmation: password)
  puts "Admin user created: #{admin_email}"
end

if Rails.env.development?
  tran = Dealer.find_or_create_by!(code: "TRAN") { |dealer| dealer.name = "Anh Trân" }
  cuong_duyen = Dealer.find_or_create_by!(code: "CUONGDUYEN") { |dealer| dealer.name = "Cường Duyên" }
  Dealer.find_or_create_by!(code: "CHERRY") { |dealer| dealer.name = "Cherry" }
  Dealer.find_or_create_by!(code: "BMW") { |dealer| dealer.name = "BMW" }

  thien_kim = Merchant.find_or_create_by!(code: "001") do |merchant|
    merchant.name = "001_ HỘ KINH DOANH THIÊN KIM GV"
    merchant.dealer = tran
  end
  thien_kim.merchant_aliases.find_or_create_by!(alias_type: "receipt_name", alias: "HỘ KINH DOANH THIÊN KIM GV")
  Merchant.find_or_create_by!(code: "TRAN3") { |merchant| merchant.name = "Trân 3"; merchant.dealer = tran }
  Merchant.find_or_create_by!(code: "CD1") { |merchant| merchant.name = "Cường Duyên 1"; merchant.dealer = cuong_duyen }
  Merchant.find_or_create_by!(code: "CD2") { |merchant| merchant.name = "Cường Duyên 2"; merchant.dealer = cuong_duyen }

  TelegramChat.find_or_create_by!(telegram_chat_id: -1001000000001) do |chat|
    chat.name = "Anh Trân - Bill (demo)"
    chat.dealer = tran
    chat.active = true
  end

  start = Time.zone.local(2026, 1, 1)
  unless FeeRule.exists?
    FeeRule.create!(base_fee_rate: BigDecimal("0.0088"), effective_from: start, priority: 100,
                    metadata: { "note" => "DEMO: system default" })
    FeeRule.create!(card_type: CardType.find_by!(key: "mb"), base_fee_rate: BigDecimal("0.011"),
                    effective_from: start, priority: 100, metadata: { "note" => "DEMO: MB cards" })
    FeeRule.create!(card_type: CardType.find_by!(key: "napas"), base_fee_rate: BigDecimal("0.0125"),
                    effective_from: start, priority: 100, metadata: { "note" => "DEMO: Napas cards" })
  end
  puts "Development sample data ready."
end
