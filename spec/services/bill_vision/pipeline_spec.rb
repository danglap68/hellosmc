require "rails_helper"

RSpec.describe BillVision::Pipeline do
  include_context "accounting setup"

  let(:bill_image) { create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat)) }
  let(:clean) { extraction_fixture("normal_settlement") }
  let(:blurry) { clean.deep_dup.tap { |data| data["documents"][0]["confidence"]["total_amount_vnd"] = 0.5 } }
  let(:endpoint) { "https://api.openai.com/v1/chat/completions" }
  let(:token_usage) { { "prompt_tokens" => 300, "prompt_tokens_details" => { "cached_tokens" => 100 }, "completion_tokens" => 200, "total_tokens" => 500 } }

  def stub_model(model, data: clean, status: 200, content: nil, finish_reason: "stop")
    body = { "model" => model, "choices" => [ { "finish_reason" => finish_reason,
                                               "message" => { "content" => content || data.to_json } } ], "usage" => token_usage }
    stub_request(:post, endpoint).with { |request| JSON.parse(request.body)["model"] == model }
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def analyze
    BillImages::Analyzer.call(bill_image, job_id: "job-1")
    bill_image.reload
  end

  def metadata
    bill_image.reload.metadata.fetch("vision_pipeline")
  end

  it "uses only Luna for a clean bill, with a strict output cap and usage telemetry" do
    request = stub_model("gpt-6-luna")
    allow(StructuredLog).to receive(:info).and_call_original
    analyze

    expect(request).to have_been_requested.once
    expect(metadata).to include("calls" => { "primary" => 1, "validator" => 0 }, "validation_result" => "skipped")
    expect(metadata.dig("primary", "usage")).to include("input_tokens" => 300, "cached_input_tokens" => 100, "output_tokens" => 200, "total_tokens" => 500)
    expect(metadata.dig("primary", "raw_output", "usage")).to eq(token_usage)
    expect(request.with { |req|
      body = JSON.parse(req.body)
      body["max_completion_tokens"] == 700 && body["reasoning_effort"] == "none" &&
        !body.key?("temperature") && body.dig("response_format", "json_schema", "strict")
    }).to have_been_requested.once
    expect(StructuredLog).to have_received(:info).with("ocr.primary.result", hash_including(bill_image_id: bill_image.id, input_tokens: 300, output_tokens: 200, request_type: :primary, model: "gpt-6-luna"))
    expect(Transactions::Builder.call(bill_image: bill_image).sole).to be_approved
  end

  it "keeps a primary tampering warning even when the validator agrees on facts and sees no anomaly" do
    data = clean.deep_dup
    data["documents"].first["image_integrity"] = { "status" => "suspicious", "evidence" => [ "Amount digits overlap a rectangular background patch" ] }
    primary = stub_model("gpt-6-luna", data: data)
    validator = stub_model("gpt-6.1-sol")
    analyze
    transaction = Transactions::Builder.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("image_tampering_suspected")
    expect(metadata.dig("calls")).to eq("primary" => 1, "validator" => 1)
    expect(metadata.dig("primary", "normalized_output", "documents", 0, "image_integrity", "evidence")).to be_present
    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
    expect(WriteHelloSmcWorkbookJob).not_to have_been_enqueued
  end

  it "keeps a risk found only by the validator and never replaces the primary receipt facts" do
    primary = stub_model("gpt-6-luna", data: blurry)
    data = clean.deep_dup
    data["documents"].first["image_integrity"] = { "status" => "suspicious", "evidence" => [ "Lot digits have a different baseline" ] }
    validator = stub_model("gpt-6.1-sol", data: data)
    analyze
    transaction = Transactions::Builder.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("image_tampering_suspected")
    expect(transaction.transaction_amount_vnd).to eq(11_445_000)
    expect(metadata.dig("validator", "normalized_output", "documents", 0, "image_integrity", "evidence")).to be_present
    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
  end

  it "requires manual review for uncertain integrity even when the optional validator is disabled" do
    allow(AppConfig).to receive(:vision_validation_enabled?).and_return(false)
    data = clean.deep_dup
    data["documents"].first["image_integrity"] = { "status" => "uncertain", "evidence" => [] }
    stub_model("gpt-6-luna", data: data)
    analyze
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("image_integrity_uncertain")
    expect(metadata.dig("calls", "validator")).to eq(0)
  end

  it "keeps a previous integrity warning after retry instead of letting repeated reads bypass manual verification" do
    data = clean.deep_dup
    data["documents"].first["image_integrity"] = { "status" => "suspicious", "evidence" => [ "Amount has visible pasted digits" ] }
    stub_model("gpt-6-luna", data: data)
    stub_model("gpt-6.1-sol")
    analyze
    stub_model("gpt-6-luna")
    BillImages::Analyzer.call(bill_image, force: true, job_id: "job-2")
    expect(bill_image.reload.ocr_attempts).to eq(2)
    expect(bill_image.documents.sole["vision_review_reasons"]).to include("image_tampering_suspected")
    expect(bill_image.metadata["vision_history"].sole.dig("primary", "normalized_output", "documents", 0, "image_integrity", "evidence")).to be_present
    expect(Transactions::Builder.call(bill_image: bill_image).sole).to be_needs_review
  end

  it "reads a meaningfully unreadable visual field independently with Sol, exactly twice" do
    primary = stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol")
    analyze

    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
    expect(metadata["validation_result"]).to eq("agreed")
    expect(metadata["validation_reason"]).to include("amount_unreadable")
    expect(metadata.dig("primary", "normalized_output", "requires_review")).to be(true)
    expect(bill_image.documents.first.dig("confidence", "total_amount_vnd")).to eq(0.5)
    expect(bill_image.documents.first["validation_confirmed_fields"]).to include("total_amount_vnd")
    expect(validator.with { |req|
      body = JSON.parse(req.body)
      body["max_completion_tokens"] == 4096 && body["reasoning_effort"] == "low" &&
        body["messages"].size == 2 && body.dig("messages", 0, "content") == BillVision::Prompt::SYSTEM &&
        body.dig("messages", 1, "content", 0, "text") == BillVision::Prompt.user(catalog: BillVision::MerchantCatalog.call)
    }).to have_been_requested.once
    expect(Transactions::Builder.call(bill_image: bill_image).sole).to be_approved
  end

  it "does not escalate solely because the primary reports .91" do
    data = clean.deep_dup
    data["documents"][0]["confidence"]["total_amount_vnd"] = 0.91
    primary = stub_model("gpt-6-luna", data: data)
    analyze
    expect(primary).to have_been_requested.once
    expect(metadata["calls"]["validator"]).to eq(0)
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("amount_low_confidence")
  end

  it "never replaces primary facts or approves when the two models disagree" do
    stub_model("gpt-6-luna", data: blurry)
    changed = clean.deep_dup
    changed["documents"][0]["total_amount_vnd"] = 10_000_000
    stub_model("gpt-6.1-sol", data: changed)
    analyze

    transaction = Transactions::Builder.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.transaction_amount_vnd).to eq(11_445_000)
    expect(transaction.review_reason_codes).to include("model_disagreement")
    expect(metadata.dig("validator", "normalized_output", "documents", 0, "total_amount_vnd")).to eq(10_000_000)
    expect(metadata["validation_result"]).to eq("disagreed")
  end

  it "sends an AI-only HKD suggestion to review without buying an additional model call" do
    data = clean.deep_dup
    data["documents"].first.merge!("merchant_name" => "THIÊN ... 1", "terminal_or_merchant_id" => nil,
                                   "merchant_match" => { "merchant_id" => merchant.id, "confidence" => 0.99 })
    primary = stub_model("gpt-6-luna", data: data)
    analyze
    expect(primary).to have_been_requested.once
    expect(metadata.dig("calls", "validator")).to eq(0)
    transaction = Transactions::Builder.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("merchant_ai_match")
  end

  it "requires review when the validator chooses a different catalog HKD" do
    other = create(:merchant, name: "Another Coffee")
    primary_data = blurry.deep_dup
    primary_data["documents"].first["merchant_match"] = { "merchant_id" => merchant.id, "confidence" => 0.99 }
    validator_data = clean.deep_dup
    validator_data["documents"].first["merchant_match"] = { "merchant_id" => other.id, "confidence" => 0.99 }
    stub_model("gpt-6-luna", data: primary_data)
    stub_model("gpt-6.1-sol", data: validator_data)
    analyze
    expect(metadata["disagreement_fields"]).to include("merchant_catalog_identity")
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("model_disagreement")
  end

  it "does not clear fee configuration errors discovered after independent agreement" do
    stub_model("gpt-6-luna", data: blurry)
    stub_model("gpt-6.1-sol")
    analyze
    default_rule.destroy!
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("fee_rule_not_found")
  end

  it "does not clear duplicate detection after independent agreement" do
    stub_model("gpt-6-luna", data: blurry)
    stub_model("gpt-6.1-sol")
    analyze
    Transactions::Builder.call(bill_image: analyzed_bill)
    transaction = Transactions::Builder.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("possible_duplicate")
  end

  it "ends in review on a validator transient failure without a third request or retry job" do
    primary = stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol", status: 429)
    AnalyzeBillImageJob.perform_now(bill_image.id)
    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(metadata["validation_result"]).to eq("validator_failed")
    expect(Transactions::Builder.call(bill_image: bill_image.reload).sole.review_reason_codes).to include("validator_failed")
  end

  it "does not escalate an unmapped dealer, even if OCR also needs review" do
    merchant_dealer_link.destroy!
    stub_model("gpt-6-luna", data: blurry)
    analyze
    expect(metadata["calls"]["validator"]).to eq(0)
    expect(metadata["deterministic_business_review_reasons"]).to include("dealer_unmapped")
  end

  it "still rereads malformed output when no agent is mapped" do
    merchant_dealer_link.destroy!
    validator = stub_model("gpt-6.1-sol")
    stub_model("gpt-6-luna", content: "invalid JSON")
    analyze
    expect(validator).to have_been_requested.once
    expect(bill_image).to be_ocr_needs_review
  end

  it "confirms equivalent MID formatting without modifying the primary identifier" do
    create(:merchant_alias, merchant: merchant, alias_type: "merchant_id", alias: "MID001")
    primary_data = blurry.deep_dup
    primary_data["documents"][0].merge!("terminal_or_merchant_id" => "mid-001")
    primary_data["documents"][0]["confidence"].merge!("terminal_or_merchant_id" => 0.5)
    validator_data = clean.deep_dup
    validator_data["documents"][0].merge!("terminal_or_merchant_id" => "MID 001")
    validator_data["documents"][0]["confidence"].merge!("terminal_or_merchant_id" => 0.99)
    stub_model("gpt-6-luna", data: primary_data)
    stub_model("gpt-6.1-sol", data: validator_data)
    analyze
    expect(bill_image.documents.first["terminal_or_merchant_id"]).to eq("mid-001")
    expect(metadata["validation_result"]).to eq("agreed")
    expect(Transactions::Builder.call(bill_image: bill_image).sole).to be_approved
  end

  it "does not escalate missing or ambiguous fee configuration" do
    default_rule.destroy!
    stub_model("gpt-6-luna", data: blurry)
    analyze
    expect(metadata["calls"]["validator"]).to eq(0)
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("fee_rule_not_found")
  end

  it "does not use a validator for duplicates" do
    Transactions::Builder.call(bill_image: analyzed_bill)
    stub_model("gpt-6-luna", data: blurry)
    analyze
    expect(metadata["calls"]["validator"]).to eq(0)
    expect(metadata["deterministic_business_review_reasons"]).to include("possible_duplicate")
  end

  it "does not mistake its own transaction for a duplicate during reprocessing" do
    primary = stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol", data: blurry)
    analyze
    expect(Transactions::Builder.call(bill_image: bill_image).sole).to be_needs_review
    BillImages::Analyzer.call(bill_image, force: true)
    expect(primary).to have_been_requested.twice
    expect(validator).to have_been_requested.twice
    expect(metadata["deterministic_business_review_reasons"]).not_to include("possible_duplicate")
  end

  it "keeps malformed primary output and usage, reads once more, and remains in review" do
    stub_model("gpt-6-luna", content: "invalid JSON")
    validator = stub_model("gpt-6.1-sol")
    analyze
    expect(validator).to have_been_requested.once
    expect(metadata.dig("primary", "raw_output", "choices", 0, "message", "content")).to eq("invalid JSON")
    expect(metadata.dig("primary", "usage", "total_tokens")).to eq(500)
    expect(metadata["calls"]).to eq("primary" => 1, "validator" => 1)
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("malformed_primary_extraction")
  end

  it "does not retry or increase the token limit for truncated structured output" do
    primary = stub_model("gpt-6-luna", finish_reason: "length")
    analyze
    expect(primary).to have_been_requested.once
    expect(metadata["calls"]["validator"]).to eq(0)
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("primary_output_truncated")
  end

  it "ends after one malformed validator response and retains its raw output and usage" do
    primary = stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol", content: "not JSON")
    AnalyzeBillImageJob.perform_now(bill_image.id)
    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(metadata["validation_result"]).to eq("validator_failed")
    expect(metadata.dig("validator", "raw_output", "choices", 0, "message", "content")).to eq("not JSON")
    expect(metadata.dig("validator", "usage", "total_tokens")).to eq(500)
  end

  it "gives the independent validator room to reason and emit JSON for multiple settlements" do
    data = clean.deep_dup
    data["documents"] << data["documents"].first.merge("lot_number" => "000117", "total_amount_vnd" => 5_000_000)
    primary = stub_model("gpt-6-luna", data: data)
    usage = token_usage.merge("completion_tokens" => 2200, "total_tokens" => 2500,
                              "completion_tokens_details" => { "reasoning_tokens" => 1600 })
    validator = stub_request(:post, endpoint).with { |request|
      body = JSON.parse(request.body)
      body["model"] == "gpt-6.1-sol" && body["max_completion_tokens"] == 4096
    }.to_return(body: { "model" => "gpt-6.1-sol", "usage" => usage,
                       "choices" => [ { "finish_reason" => "stop", "message" => { "content" => data.to_json } } ] }.to_json)

    analyze

    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
    expect(metadata["calls"]).to eq("primary" => 1, "validator" => 1)
    expect(metadata["validation_reason"]).to include("multiple_settlement_documents")
    expect(metadata["validation_result"]).to eq("agreed")
    expect(metadata.dig("validator", "usage")).to include("output_tokens" => 2200, "reasoning_tokens" => 1600)
    expect(bill_image.documents.size).to eq(2)
  end

  it "keeps a truncated validator in review without retrying or raising its fixed cap" do
    primary = stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol", content: "", finish_reason: "length")

    AnalyzeBillImageJob.perform_now(bill_image.id)

    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(metadata["calls"]).to eq("primary" => 1, "validator" => 1)
    expect(metadata["validation_result"]).to eq("validator_failed")
    expect(metadata.dig("validator", "raw_output", "choices", 0, "finish_reason")).to eq("length")
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("validator_failed")
  end

  it "keeps review when the validator is still unreadable after one call" do
    stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol", data: blurry)
    analyze
    expect(validator).to have_been_requested.once
    expect(metadata["validation_result"]).to eq("unresolved")
    expect(Transactions::Builder.call(bill_image: bill_image).sole).to be_needs_review
  end

  it "preserves refusal metadata and does not reread a refused primary response" do
    request = stub_request(:post, endpoint).to_return(body: {
      "model" => "gpt-6-luna", "choices" => [ { "message" => { "refusal" => "Cannot extract" } } ], "usage" => token_usage
    }.to_json)
    analyze
    expect(request).to have_been_requested.once
    expect(metadata["calls"]["validator"]).to eq(0)
    expect(metadata.dig("primary", "usage", "output_tokens")).to eq(200)
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("primary_refused")
  end

  it "keeps review when both models agree on missing facts" do
    data = clean.deep_dup
    data["documents"][0]["total_amount_vnd"] = nil
    data["documents"][0]["confidence"]["total_amount_vnd"] = 0
    stub_model("gpt-6-luna", data: data)
    stub_model("gpt-6.1-sol", data: data)
    analyze
    expect(metadata["validation_result"]).to eq("unresolved")
    expect(Transactions::Builder.call(bill_image: bill_image).sole).to be_needs_review
  end

  it "caps transient primary retries at three requests across repeated deliveries of the same job" do
    primary = stub_model("gpt-6-luna", status: 503)
    3.times do
      expect { BillImages::Analyzer.call(bill_image, force: true, job_id: "same-job") }.to raise_error(BillVision::TransientError)
    end
    expect(BillImages::Analyzer.call(bill_image, force: true, job_id: "same-job").status).to eq(:analyzed)
    expect(primary).to have_been_requested.times(3)
    expect(bill_image.reload.ocr_attempts).to eq(3)
    expect(bill_image.metadata["vision_history"].size).to eq(2)
    expect(Transactions::Builder.call(bill_image: bill_image).sole.review_reason_codes).to include("validation_budget_exhausted")
  end

  it "counts forced reprocessing against the same six-request ceiling" do
    primary = stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol")
    5.times { BillImages::Analyzer.call(bill_image, force: true) }
    expect(primary).to have_been_requested.times(3)
    expect(validator).to have_been_requested.times(3)
    expect(bill_image.reload.ocr_attempts).to eq(3)
    expect(bill_image.metadata["vision_history"].size).to eq(2)
  end

  it "caps actual ActiveJob timeout retries at three network attempts" do
    primary = stub_request(:post, endpoint).to_timeout
    perform_enqueued_jobs(only: AnalyzeBillImageJob) { AnalyzeBillImageJob.perform_later(bill_image.id) }
    expect(primary).to have_been_requested.times(3)
    expect(bill_image.reload.ocr_attempts).to eq(3)
    expect(bill_image).to be_ocr_failed
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
    expect(metadata["calls"]).to eq("primary" => 1, "validator" => 0)
  end

  it "honors a lower configured run cap even for forced jobs" do
    ENV["OCR_MAX_ATTEMPTS"] = "1"
    primary = stub_model("gpt-6-luna", data: blurry)
    validator = stub_model("gpt-6.1-sol")
    3.times { BillImages::Analyzer.call(bill_image, force: true) }
    expect(primary).to have_been_requested.once
    expect(validator).to have_been_requested.once
    expect(bill_image.reload.ocr_attempts).to eq(1)
    expect(bill_image).to be_ocr_needs_review
  end

  it "retains Gemini extraction without calling OpenAI validation" do
    ENV["OCR_PROVIDER"] = "gemini"
    ENV["GEMINI_API_KEY"] = "test-gemini-key"
    request = stub_request(:post, %r{generativelanguage.googleapis.com/v1beta/models/.*:generateContent}).to_return(body: {
      "candidates" => [ { "content" => { "parts" => [ { "text" => blurry.to_json } ] } } ], "modelVersion" => "gemini-test"
    }.to_json)
    analyze
    expect(request).to have_been_requested.once
    expect(bill_image.ocr_provider).to eq("gemini")
    expect(metadata["calls"]).to eq("primary" => 1, "validator" => 0)
    expect(bill_image).to be_ocr_needs_review
  end

  it "honors disabling validation without changing Gemini or offline provider selection" do
    ENV["OCR_VALIDATION_ENABLED"] = "false"
    primary = stub_model("gpt-6-luna", data: blurry)
    analyze
    expect(primary).to have_been_requested.once
    expect(metadata["calls"]["validator"]).to eq(0)
    expect(bill_image).to be_ocr_needs_review
  end

  it "does not automatically retry permanent authentication errors or log echoed secrets" do
    secret = "echoed-private-credential"
    stub_request(:post, endpoint).to_return(status: 401, body: { "error" => secret }.to_json)
    allow(StructuredLog).to receive(:error).and_call_original
    analyze
    expect(bill_image).to be_ocr_failed
    expect(bill_image.metadata["ocr_retryable"]).to be(false)
    RetryFailedExtractionJob.perform_now
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(bill_image.processing_error).not_to include(secret)
    expect(bill_image.metadata.to_json).not_to include(secret)
    expect(StructuredLog).to have_received(:error).with("ocr.failed", hash_including(error: "openai HTTP 401"))
  end
end
