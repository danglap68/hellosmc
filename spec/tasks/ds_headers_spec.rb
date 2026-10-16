require "rails_helper"
require "rake"

RSpec.describe "hellosmc:ds_headers" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "hellosmc:ds_headers:check" } }

  let(:hkd) { create(:merchant, name: "Cherry Coffee", code: "CHERRY001") }
  let!(:link) do
    create(:merchant_dealer, merchant: hkd, dealer: create(:dealer, name: "Nghĩa Nghiệp"), tid_key: "tid1",
           ds_sheet_anchor: "Cherry Coffee", ds_header: "Nghĩa Nghiệp (tid1)")
  end

  before do
    AppSetting.create!(key: "hello_smc_spreadsheet_id", value: "1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-aBc")
    sheet = Workbook::MemorySheet.new("DS MB T#{Time.current.month}" => [ [ "Cherry Coffee", "Nghĩa (tid1)" ] ])
    allow(Workbook::GoogleSheetClient).to receive(:new).and_return(sheet)
  end

  after do
    Rake::Task["hellosmc:ds_headers:check"].reenable
    Rake::Task["hellosmc:ds_headers:sync"].reenable
  end

  it "check reports the difference and changes nothing" do
    expect { Rake::Task["hellosmc:ds_headers:check"].invoke }.to output(/renamed 1.*Cherry Coffee \/ tid1/m).to_stdout
    expect(link.reload.ds_header).to eq("Nghĩa Nghiệp (tid1)")
  end

  it "sync applies it" do
    expect { Rake::Task["hellosmc:ds_headers:sync"].invoke }.to output(/renamed 1/).to_stdout
    expect(link.reload.ds_header).to eq("Nghĩa (tid1)")
  end
end
