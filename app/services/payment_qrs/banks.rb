module PaymentQrs
  module Banks
    module_function

    def all
      # Keep the full recipient catalog. transferSupported describes the
      # bank app's scanning capability, not a filter for recipient accounts.
      @all ||= JSON.parse(Rails.root.join("config/vietqr_banks.json").read).fetch("banks").freeze
    end

    def name(bin)
      all.find { |bank| bank["bin"] == bin }&.fetch("shortName")
    end

    def options
      all.map { |bank| [ "#{bank.fetch('shortName')} — #{bank.fetch('name')}", bank.fetch("bin") ] }
    end
  end
end
