module BillVision
  # Only the configured business names are shared: no fees, balances or accounts.
  # Load a fresh, complete catalog for each image request, including validation.
  module MerchantCatalog
    module_function

    def call
      Merchant.active.includes(:merchant_aliases).order(:id).map do |merchant|
        aliases = merchant.merchant_aliases.select { |entry| entry.active? && !entry.identifier? }.map(&:alias).sort
        { id: merchant.id, name: merchant.name, aliases: aliases }
      end
    end

    def valid_matches?(data, catalog)
      ids = catalog.pluck(:id)
      data.fetch("documents").all? do |document|
        document["merchant_match"].nil? || ids.include?(document.dig("merchant_match", "merchant_id"))
      end
    end
  end
end
