class FeeRuleCardType < ApplicationRecord
  belongs_to :fee_rule
  belongs_to :card_type
end
