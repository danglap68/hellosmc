class FeeRuleMerchant < ApplicationRecord
  has_paper_trail

  belongs_to :fee_rule
  belongs_to :merchant
end
