# Idempotent seeds. Safe to run repeatedly.
#
#   SEED_ADMIN_EMAIL=admin@example.com SEED_ADMIN_PASSWORD=... bin/rails db:seed
#
# Sample dealers/merchants are created in development only. Fee rules are the
# real ones (FeeRules::Seed, created only when missing, never overwritten).

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

# Hello SMC workbook: remitters + agent×HKD mapping (idempotent).
Workbook::Seed.call

# Real fee rules (needs the HKDs above). Skips rules that already exist, so
# rates edited in the admin are kept.
FeeRules::Seed.call
puts "Fee rules: #{FeeRule.count}"

admin_email = ENV["SEED_ADMIN_EMAIL"].presence || "danglap686868@gmail.com"
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
  end
  thien_kim.merchant_aliases.find_or_create_by!(alias_type: "receipt_name", alias: "HỘ KINH DOANH THIÊN KIM GV")
  Merchant.find_or_create_by!(code: "TRAN3") { |merchant| merchant.name = "Trân 3" }
  Merchant.find_or_create_by!(code: "CD1") { |merchant| merchant.name = "Cường Duyên 1" }
  Merchant.find_or_create_by!(code: "CD2") { |merchant| merchant.name = "Cường Duyên 2" }

  # Groups named "TenDaiLy-HKD1[-HKD2]" with their HKDs (development demo ids).
  Workbook::Seed.seed_telegram_chats

  puts "Development sample data ready."
end
