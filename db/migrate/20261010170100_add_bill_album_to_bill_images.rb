class AddBillAlbumToBillImages < ActiveRecord::Migration[8.1]
  def change
    add_reference :bill_images, :bill_album, foreign_key: true
  end
end
