namespace :telegram do
  desc "Register the production webhook: bin/rails 'telegram:set_webhook[https://example.com/webhooks/telegram]'"
  task :set_webhook, [ :url ] => :environment do |_task, args|
    url = args[:url].presence || "https://#{ENV.fetch('APP_HOST')}/webhooks/telegram"
    secret = AppConfig.telegram_webhook_secret
    abort "Set TELEGRAM_WEBHOOK_SECRET first." if secret.nil? && Rails.env.production?

    Telegram::BotClient.new.set_webhook(url: url, secret_token: secret)
    puts "Webhook set to #{url}"
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
