class FeeRuleCardType < ApplicationRecord
  has_paper_trail

  belongs_to :fee_rule
  belongs_to :card_type
end
