module Admin
  class DashboardController < BaseController
    permission :dashboard

    def index
      @period = params[:period].to_s
      @period = "30d" unless @period.in?(Dashboard::Stats::PERIODS)
      @stats = Dashboard::Stats.new(period: @period)
    end
  end
end
