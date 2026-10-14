require "rails_helper"

RSpec.describe "Payment QR Telegram jobs" do
  include_context "payment QR setup"
  let(:client) { instance_double(Telegram::BotClient) }

  before { allow(Telegram::BotClient).to receive(:new).and_return(client) }

  it "never calls Telegram while the trial switch is off" do
    qr = payment_qr
    expect(client).not_to receive(:send_message)
    expect(client).not_to receive(:send_photo)
    DeliverPaymentQrJob.perform_now(qr.id, "summary")
    expect(qr.reload.summary_delivery).to eq("idle")
  end

  context "enabled" do
    before { enable_payment_telegram }

    def callback(qr, action = "confirm", user: 123456, chat: qr.source_chat.telegram_chat_id, message: qr.summary_message_id)
      { "id" => "callback-1", "data" => "pqr:#{action}:#{qr.access_token}", "from" => { "id" => user },
        "message" => { "message_id" => message, "chat" => { "id" => chat } } }
    end

    it "sends the summary once with group callbacks and a direct-link Mini App" do
      qr = payment_qr
      expect(client).to receive(:send_message).once do |**params|
        expect(params[:chat_id]).to eq(qr.source_chat.telegram_chat_id)
        expect(params[:text]).to include("9.860.000 VND", "AS2", "076802960001")
        keyboard = JSON.parse(params.fetch(:reply_markup)).fetch("inline_keyboard")
        expect(keyboard.flatten.first.fetch("callback_data").bytesize).to be <= 64
        expect(keyboard.flatten.find { |button| button["url"] }.fetch("url")).to include("https://t.me/smc_test_bot?startapp=pqr_")
        { "message_id" => 555 }
      end
      2.times { DeliverPaymentQrJob.perform_now(qr.id, "summary") }
      expect(qr.reload.summary_delivery).to eq("sent")
      expect(qr.summary_message_id).to eq(555)
    end

    it "does not resend after a network timeout with unknown delivery status" do
      qr = payment_qr
      expect(client).to receive(:send_message).once.and_raise(Telegram::BotClient::TransientError, "timeout")
      2.times { DeliverPaymentQrJob.perform_now(qr.id, "summary") }
      expect(qr.reload.summary_delivery).to eq("uncertain")
      expect(qr.delivery_error).to be_present
    end

    it "ignores stale QR delivery after a bill is put on hold" do
      qr = payment_qr
      PaymentQrs::Decide.call(request: qr, decision: "confirm", version: qr.lock_version)
      payment_transaction.transition_to!("hold")
      expect(client).not_to receive(:send_photo)
      DeliverPaymentQrJob.perform_now(qr.id, "qr")
    end

    it "handles duplicate native confirmation callbacks and sends a single QR" do
      qr = payment_qr
      qr.update!(summary_message_id: 555, summary_delivery: "sent")
      payload = callback(qr)
      allow(client).to receive(:answer_callback_query)
      2.times { ProcessPaymentQrCallbackJob.perform_now(payload) }
      expect(qr.reload).to be_confirmed
      expect(qr.confirmed_by_telegram_id).to eq(123456)
      expect(AuditLog.where(action: "payment_qr.confirmed").count).to eq(1)
      expect(client).to receive(:send_photo).once do |**params|
        expect(params[:png]).to start_with("\x89PNG".b)
        expect(params[:caption]).to include("9.860.000 VND", "AS2")
        { "message_id" => 556 }
      end
      2.times { DeliverPaymentQrJob.perform_now(qr.id, "qr") }
      expect(qr.reload.qr_message_id).to eq(556)
    end

    it "refuses unlisted actors and callbacks copied to another group or message" do
      qr = payment_qr
      qr.update!(summary_message_id: 555, summary_delivery: "sent")
      allow(client).to receive(:answer_callback_query)
      [ callback(qr, user: 999), callback(qr, chat: -123), callback(qr, message: 777) ].each do |payload|
        ProcessPaymentQrCallbackJob.perform_now(payload)
        expect(qr.reload).to be_pending
      end
      expect(AuditLog.where(action: "payment_qr.confirmed")).not_to exist
    end

    it "stops before delivery when the group has no authorized confirmers" do
      qr = payment_qr
      qr.source_chat.update!(payment_qr_confirmer_ids: [])
      expect(client).not_to receive(:send_message)
      DeliverPaymentQrJob.perform_now(qr.id, "summary")
    end
  end
end
