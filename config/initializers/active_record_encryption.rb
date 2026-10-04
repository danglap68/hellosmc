# Active Record Encryption keys derived from SECRET_KEY_BASE, so no
# credentials file is needed. Changing SECRET_KEY_BASE makes AppSecret values
# unreadable: enter them again under Cài đặt afterwards.
Rails.application.configure do
  key_generator = Rails.application.key_generator
  derive = ->(purpose) { key_generator.generate_key("active_record_encryption/#{purpose}", 32).unpack1("H*") }

  config.active_record.encryption.primary_key = derive.call("primary_key")
  config.active_record.encryption.deterministic_key = derive.call("deterministic_key")
  config.active_record.encryption.key_derivation_salt = derive.call("key_derivation_salt")
end
