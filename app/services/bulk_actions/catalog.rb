module BulkActions
  # Explicit allowlist: neither model names nor methods come from request input.
  module Catalog
    CONFIGURATION_ACTIONS = %w[activate deactivate destroy].freeze
    RESOURCES = {
      "transactions" => [ Transaction, :transactions, %w[approve hold reject reprocess] ],
      "reviews" => [ Transaction, :reviews, %w[approve hold reject reprocess] ],
      "remitter_transfers" => [ RemitterTransfer, :remitter_transfers, %w[approve reject retry write] ],
      "dealers" => [ Dealer, :dealers, CONFIGURATION_ACTIONS ],
      "merchants" => [ Merchant, :merchants, CONFIGURATION_ACTIONS ],
      "remitters" => [ Remitter, :remitters, CONFIGURATION_ACTIONS ],
      "telegram_chats" => [ TelegramChat, :telegram_chats, CONFIGURATION_ACTIONS + %w[process_stored] ],
      "fee_rules" => [ FeeRule, :fee_rules, CONFIGURATION_ACTIONS ],
      "card_types" => [ CardType, :card_types, CONFIGURATION_ACTIONS ],
      "users" => [ User, :users, CONFIGURATION_ACTIONS ],
      "transfer_codes" => [ MerchantDealer, :transfer_codes, %w[destroy] ],
      "merchant_aliases" => [ MerchantAlias, :merchants, CONFIGURATION_ACTIONS ]
    }.freeze

    def self.version(record)
      record.has_attribute?(:lock_version) ? record.lock_version.to_s : record.updated_at.utc.iso8601(6)
    end
  end
end
