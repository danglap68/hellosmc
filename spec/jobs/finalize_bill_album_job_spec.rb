require "rails_helper"

RSpec.describe FinalizeBillAlbumJob do
  let(:album) { create(:bill_album, collect_until: 1.hour.ago) }

  def normalized(document)
    BillVision::Normalizer.call({ "documents" => [ document ] }, provider: "openai", model: "gpt-test")
  end

  it "waits while the collect window is still open" do
    album.update!(collect_until: 5.minutes.from_now)

    expect { described_class.perform_now(album.id) }
      .to have_enqueued_job(described_class).with(album.id)

    expect(album.reload).to be_collecting
  end

  it "waits while messages still need to be downloaded" do
    create(:telegram_message, telegram_chat: album.telegram_chat, media_group_id: album.media_group_id,
                              processing_status: "queued")

    expect { described_class.perform_now(album.id) }
      .to have_enqueued_job(described_class).with(album.id)
  end

  it "waits while images are still being OCR'd" do
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: album.telegram_chat),
                        ocr_status: "processing")

    expect { described_class.perform_now(album.id) }
      .to have_enqueued_job(described_class).with(album.id)
  end

  it "reconciles once every image is done" do
    child = { "document_type" => "child_receipt", "total_amount_vnd" => 100_000_000,
              "transaction_date" => "2026-10-04", "transaction_time" => "12:00:00",
              "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV", "terminal_or_merchant_id" => nil }
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: album.telegram_chat),
                        ocr_status: "completed", normalized_extraction: normalized(child))
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: album.telegram_chat),
                        ocr_status: "completed", normalized_extraction: normalized(
                          { "document_type" => "transfer", "total_amount_vnd" => 100_000_000,
                            "transaction_date" => "2026-10-04", "transaction_time" => "12:00:00" }
                        ))

    described_class.perform_now(album.id)

    expect(album.reload.status).to eq("reconciled")
    expect(album.reconciliation_status).to eq("matched")
  end

  it "does nothing for an already finalized album" do
    album.update!(status: "reconciled", reconciliation_status: "matched")
    expect(BillAlbums::Reconciler).not_to receive(:call)
    described_class.perform_now(album.id)
  end
end
