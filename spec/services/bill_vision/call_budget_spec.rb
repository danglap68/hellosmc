require "rails_helper"

RSpec.describe BillVision::CallBudget do
  it "refuses a second call of either stage and never expands its budget" do
    budget = described_class.new
    budget.consume!(:primary)
    expect { budget.consume!(:primary) }.to raise_error(BillVision::BudgetExhausted)
    budget.consume!(:validator)
    expect { budget.consume!(:validator) }.to raise_error(BillVision::BudgetExhausted)
    expect(budget.snapshot["calls"]).to eq("primary" => 1, "validator" => 1)
  end

  it "reserves requests persistently and refuses another delivery of the same run" do
    bill = create(:bill_image, ocr_status: "processing", metadata: {
      "vision_pipeline" => { "run_id" => "run", "calls" => { "primary" => 0, "validator" => 0 } }
    })
    described_class.new(bill_image: bill, run_id: "run").consume!(:primary)
    restarted = described_class.new(bill_image: BillImage.find(bill.id), run_id: "run")
    expect { restarted.consume!(:primary) }.to raise_error(BillVision::BudgetExhausted)
    expect(bill.reload.metadata.dig("vision_pipeline", "calls", "primary")).to eq(1)
  end

  it "refuses a stale worker after another run claimed the bill" do
    bill = create(:bill_image, ocr_status: "processing", metadata: {
      "vision_pipeline" => { "run_id" => "new", "calls" => { "primary" => 0, "validator" => 0 } }
    })
    expect { described_class.new(bill_image: bill, run_id: "old").consume!(:primary) }.to raise_error(BillVision::BudgetExhausted)
  end
end
