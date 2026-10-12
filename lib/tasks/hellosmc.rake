namespace :telegram do
  desc "Register the webhook with a new secret (same as Cài đặt → Telegram): bin/rails 'telegram:set_webhook[https://host/webhooks/telegram]'"
  task :set_webhook, [ :url ] => :environment do |_task, args|
    url = Telegram::Connection.register_webhook!(actor: nil, url: args[:url].presence || Telegram::Connection.webhook_url)
    puts "Webhook set to #{url}"
  rescue Telegram::Connection::Error => e
    abort e.message
  end

  desc "Remove the webhook (required before local polling)"
  task delete_webhook: :environment do
    Telegram::BotClient.new.delete_webhook
    puts "Webhook deleted"
  end

  desc "Show current webhook status"
  task webhook_info: :environment do
    puts JSON.pretty_generate(Telegram::BotClient.new.webhook_info)
  end
end

namespace :hellosmc do
  desc "Generate yesterday's Excel export (schedule with cron)"
  task export_daily: :environment do
    GenerateDailyExcelJob.perform_now
  end

  desc "Check the Cloudflare R2 credentials: write, read, presigned URL and delete a test object"
  task check_r2: :environment do
    result = R2Check.call
    result.steps.each do |step|
      puts "#{step.ok? ? 'OK  ' : 'FAIL'} #{step.name}#{" - #{step.error.class}: #{step.error.message}" unless step.ok?}"
    end
    abort "R2 check failed." unless result.ok?
    puts "R2 OK (#{result.duration_ms} ms)"
  end

  desc "Retry OCR for failed bill images that still have attempts left"
  task retry_failed_extractions: :environment do
    RetryFailedExtractionJob.perform_now
  end

  desc "Build the clean \"thu chi mẫu\" tab from the newest day tab (SOURCE=\"thu chi 1110\" to pick one); day tabs are then made from it"
  task build_thu_chi_template: :environment do
    client = Workbook::GoogleSheetClient.new(spreadsheet_id: AppConfig.hello_smc_spreadsheet_id)
    report = Workbook::ThuChiTemplate.build!(client: client, source: ENV["SOURCE"].presence)
    puts "Created \"#{report.title}\" from \"#{report.source}\": #{report.amounts_cleared} amounts and " \
         "#{report.notes_cleared} RT notes cleared. Check the manual accounting area at the bottom of the tab."
  rescue Workbook::ThuChiTemplate::Error => e
    abort e.message
  end

  desc "Re-enqueue the Hello SMC sheet write for approved transactions that never reached the sheet (schedule every ~10 min)"
  task retry_workbook_writes: :environment do
    puts "Enqueued #{RetryWorkbookWritesJob.perform_now.to_i} sheet write(s)"
  end

  desc "Run OCR on a local image without saving anything: bin/rails 'hellosmc:ocr[path/to/bill.jpg]'"
  task :ocr, [ :path ] => :environment do |_task, args|
    path = args[:path] or abort "Usage: bin/rails 'hellosmc:ocr[path/to/bill.jpg]'"
    bytes = File.binread(path)
    mime_type = Marcel::MimeType.for(StringIO.new(bytes))
    result = BillVision::Extractor.call(image: BillVision::Image.new(bytes: bytes, mime_type: mime_type))
    normalized = BillVision::Normalizer.call(result.data, provider: result.provider, model: result.model)
    puts JSON.pretty_generate(normalized)
  end
end

namespace :hellosmc do
  desc "Development only: push the sample bills in spec/fixtures through the real pipeline (offline OCR)"
  task demo: :environment do
    abort "Development only." unless Rails.env.development?

    ActiveJob::Base.queue_adapter = :inline
    dealer = Dealer.find_by(code: "TRAN") or abort "Run bin/rails db:seed first."
    admin = User.find_by(role: "admin")
    samples = {
      "normal_settlement.jpg" => [ "normal_settlement", nil ],
      "mb_settlement.jpg" => [ "mb_settlement", "mb" ],
      "blurry_settlement.jpg" => [ "blurry_settlement", nil ],
      "two_settlements.jpg" => [ "two_settlements", nil ]
    }

    samples.each do |file, (fixture, card_type_key)|
      path = Rails.root.join("spec/fixtures/bills", file)
      provider = BillVision::FakeProvider.new(fixture_path: Rails.root.join("spec/fixtures/extractions/#{fixture}.json"))
      upload = BillUploadForm.new(image: Rack::Test::UploadedFile.new(path, "image/jpeg"), dealer_id: dealer.id,
                                  card_type_key: card_type_key, note: "demo", user: admin)
      bill_image = upload.save
      if bill_image
        BillImages::Analyzer.call(bill_image, extractor: BillVision::Extractor.new(provider: provider))
        BuildTransactionJob.perform_now(bill_image.id)
        puts "#{file}: #{bill_image.reload.transactions.map { |t| "##{t.id} #{t.status}" }.join(', ')}"
      else
        puts "#{file}: skipped (#{upload.errors.full_messages.to_sentence})"
      end
    end
  end
end

namespace :hellosmc do
  # Wipes everything a bill produced, keeps configuration.
  #
  # Deleted: transactions, reviews, workbook entries, remitter transfers, bill images (and their
  # files on R2), albums, Telegram messages, Excel exports, the audit log of
  # those records, and every queued/retrying/scheduled Sidekiq job.
  # Kept: users, settings, secrets (bot token, webhook), card types, dealers,
  # merchants + aliases, merchant_dealers (TID mapping), fee rules, remitters,
  # Telegram groups and their HKD mapping.
  #
  # The Google Sheet is NOT touched: rows already written stay there.
  #
  #   CONFIRM=yes bin/rails hellosmc:purge_transaction_data
  PURGE_DATA_TABLES = %w[workbook_entries transaction_reviews transactions remitter_transfers bill_images bill_albums
                   telegram_messages excel_exports].freeze
  PURGE_RECORD_TYPES = %w[Transaction TransactionReview WorkbookEntry RemitterTransfer BillImage BillAlbum
                         TelegramMessage ExcelExport].freeze

  desc "Delete all transaction data (bills, transactions, messages, exports) but keep configuration. CONFIRM=yes required"
  task purge_transaction_data: :environment do
    require "sidekiq/api"

    counts = PURGE_DATA_TABLES.index_with { |table| ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i }
    attachments = ActiveStorage::Attachment.where(record_type: %w[BillImage ExcelExport])
    blob_ids = attachments.distinct.pluck(:blob_id)
    blob_keys = ActiveStorage::Blob.where(id: blob_ids).pluck(:key)
    audit_logs = AuditLog.where(auditable_type: PURGE_RECORD_TYPES)

    puts "Database: #{ActiveRecord::Base.connection.current_database}"
    counts.each { |table, count| puts format("  %-22s %d", table, count) }
    puts format("  %-22s %d", "files (R2)", blob_keys.size)
    puts format("  %-22s %d", "audit_logs", audit_logs.count)
    puts format("  %-22s %d", "sidekiq jobs", Sidekiq::Queue.all.sum(&:size) + Sidekiq::RetrySet.new.size +
                                               Sidekiq::ScheduledSet.new.size)

    unless ENV["CONFIRM"] == "yes"
      puts "\nNothing deleted. Re-run with CONFIRM=yes to delete the above."
      next
    end

    # Jobs first, so nothing recreates rows or touches ids that are about to go.
    Sidekiq::Queue.all.each(&:clear)
    Sidekiq::RetrySet.new.clear
    Sidekiq::ScheduledSet.new.clear

    ActiveRecord::Base.transaction do
      audit_logs.delete_all
      attachments.delete_all
      ActiveStorage::VariantRecord.where(blob_id: blob_ids).delete_all
      ActiveStorage::Blob.where(id: blob_ids).delete_all
      # No CASCADE: Postgres refuses if any table outside this list still
      # references these rows, so configuration can never be truncated by accident.
      ActiveRecord::Base.connection.execute("TRUNCATE #{PURGE_DATA_TABLES.join(', ')} RESTART IDENTITY")
    end

    failed = 0
    blob_keys.each do |key|
      ActiveStorage::Blob.service.delete(key)
    rescue StandardError => e
      failed += 1
      warn "Could not delete file #{key}: #{e.class}: #{e.message}" if failed <= 3
    end

    puts "\nDeleted. Files removed from storage: #{blob_keys.size - failed}/#{blob_keys.size}."
    puts "#{failed} file(s) are left in the bucket (orphans, harmless; delete them in Cloudflare if needed)." if failed.positive?
  end
end
