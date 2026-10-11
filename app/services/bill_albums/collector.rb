module BillAlbums
  # Groups a persisted Telegram image message into its media-group album.
  # Collection only creates/links the album and extends the collect window; it
  # never enqueues finalization. Finalization is triggered by the download and
  # analyze jobs, so albums of inactive chats (images stored but not downloaded)
  # are never finalized prematurely.
  class Collector
    def self.call(message)
      new(message).call
    end

    def initialize(message)
      @message = message
    end

    def call
      return unless @message.media_group_id.present?

      album = find_or_create_album
      album.with_lock do
        message_ids = (Array(album.metadata["message_ids"]) | [ @message.id ]).sort
        album.update!(
          collect_until: Time.current + AppConfig.album_collect_window_seconds.seconds,
          metadata: album.metadata.merge("message_ids" => message_ids)
        )
      end
      album
    end

    private

    def find_or_create_album
      BillAlbum.find_or_create_by!(telegram_chat: @message.telegram_chat, media_group_id: @message.media_group_id)
    end
  end
end
