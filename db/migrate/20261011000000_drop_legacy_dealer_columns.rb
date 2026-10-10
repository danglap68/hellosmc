class DropLegacyDealerColumns < ActiveRecord::Migration[8.1]
  def up
    # Best-effort backfill: the dealer is now the TID agent via merchant_dealers.
    # Only merchants that have no merchant_dealers yet are mapped, with a default
    # tid1; the real (HKD, agent, TID) pairs come from the DS MB seed.
    Merchant.where.not(dealer_id: nil).find_each do |merchant|
      next if merchant.merchant_dealers.exists?

      dealer = Dealer.find_by(id: merchant.dealer_id)
      next unless dealer

      merchant.merchant_dealers.create!(
        dealer: dealer, tid_key: "tid1", tid_label: "tid1",
        ds_sheet_anchor: merchant.name, ds_header: dealer.name, rd_agent_label: dealer.name
      )
    end

    remove_reference :telegram_chats, :dealer, foreign_key: true
    remove_reference :merchants, :dealer, foreign_key: true
  end

  def down
    add_reference :merchants, :dealer, foreign_key: true
    add_reference :telegram_chats, :dealer, foreign_key: true
  end
end
