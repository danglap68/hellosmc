module Admin
  class BulkActionsController < BaseController
    private

    def authorize_access!
      config = BulkActions::Catalog::RESOURCES[params[:resource].to_s]
      forbid! unless config && can?(:manage, config[1])
    end

    public

    def create
      results = BulkActions::Runner.new(
        resource: params[:resource], operation: params[:operation], actor: current_user,
        ids: params[:ids], versions: params[:versions].is_a?(ActionController::Parameters) ? params[:versions].permit!.to_h : {},
        note: params[:note]
      ).call
      success_count = results.count { |row| row[:success] }
      render json: { results: results, message: t("bulk.result", success: success_count, failed: results.size - success_count) }
    rescue BulkActions::Runner::InvalidSelection => error
      render json: { message: error.message }, status: :unprocessable_content
    end
  end
end
