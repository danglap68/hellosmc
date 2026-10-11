# Album orchestration: waits until the collect window expired, every message is
# downloaded and every image is OCR'd, then reconciles the album once.
class FinalizeBillAlbumJob < ApplicationJob
  queue_as :default

  # Bounds the "wait for download/OCR" re-schedules (~30 minutes of 5s waits)
  # so a permanently stuck image cannot loop forever.
  MAX_WAIT_ATTEMPTS = 360

  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5

  def perform(album_id)
    album = BillAlbum.find(album_id)
    return if album.terminal?

    if album.collect_until.present? && Time.current < album.collect_until
      reschedule(wait: album.collect_until - Time.current)
      return
    end

    if album.messages_without_images? || album.images_pending_ocr?
      waits = album.metadata["finalize_waits"].to_i + 1
      if waits > MAX_WAIT_ATTEMPTS
        album.update!(status: "failed", metadata: album.metadata.merge("finalize_error" => "waited too long for album OCR"))
        StructuredLog.error("bill_album.finalize_stuck", bill_album_id: album.id)
        return
      end
      album.update!(metadata: album.metadata.merge("finalize_waits" => waits))
      reschedule(wait: 5.seconds)
      return
    end

    BillAlbums::Reconciler.call(album)
  end

  private

  def reschedule(wait:)
    self.class.set(wait: wait).perform_later(arguments.first)
  end
end
