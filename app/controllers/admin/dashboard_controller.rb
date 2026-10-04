module Admin
  class DashboardController < BaseController
    permission :dashboard

    def index
      @stats = Dashboard::Stats.new
    end
  end
end
