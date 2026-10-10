require "rails_helper"

RSpec.describe BillAlbums::Collector do
  let(:chat) { create(:telegram_chat) }

  def image_message(media_group_id)
    create(:telegram_message, telegram_chat: chat, media_group_id: media_group_id)
  end

  it "groups messages of the same media group into one album" do
    first = image_message("mg-1")
    second = image_message("mg-1")

    described_class.call(first)
    described_class.call(second)

    album = BillAlbum.find_by!(telegram_chat: chat, media_group_id: "mg-1")
    expect(album.metadata["message_ids"]).to eq([ first.id, second.id ])
  end

  it "creates separate albums for different media groups" do
    described_class.call(image_message("mg-1"))
    described_class.call(image_message("mg-2"))
    expect(BillAlbum.where(telegram_chat: chat).count).to eq(2)
  end

  it "does nothing for a message without a media group" do
    message = create(:telegram_message, telegram_chat: chat, media_group_id: nil)
    expect { described_class.call(message) }.not_to change(BillAlbum, :count)
  end

  it "extends the collect window for every new message" do
    first = image_message("mg-1")
    described_class.call(first)
    album = BillAlbum.find_by!(telegram_chat: chat, media_group_id: "mg-1")
    before = album.collect_until

    travel 1.minute
    described_class.call(image_message("mg-1"))
    expect(album.reload.collect_until).to be > before
  end
end
