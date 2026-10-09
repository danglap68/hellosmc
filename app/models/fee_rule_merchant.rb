class FeeRuleMerchant < ApplicationRecord
  belongs_to :fee_rule
  belongs_to :merchant
end
