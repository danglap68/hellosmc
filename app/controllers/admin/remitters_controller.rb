module Admin
  class RemittersController < BaseController
    permission :remitters

    before_action :set_remitter, only: %i[edit update destroy]

    def index
      scope = Remitter.all
      if params[:q].present?
        q = "%#{Remitter.sanitize_sql_like(params[:q])}%"
        scope = scope.where("remitters.name ILIKE :q OR remitters.excel_key ILIKE :q OR remitters.telegram_username ILIKE :q", q: q)
      end
      scope = apply_active_filter(scope)
      scope = apply_sort(scope, {
        "oldest" => { id: :asc },
        "newest" => { id: :desc },
        "name_asc" => { name: :asc, id: :asc },
        "name_desc" => { name: :desc, id: :asc }
      }, default: "oldest")
      @pagy, @remitters = pagy(scope)
    end

    def new
      @remitter = Remitter.new(active: true)
    end

    def create
      @remitter = Remitter.new(remitter_params)
      if @remitter.save
        audit!("remitter.created", @remitter)
        redirect_to admin_remitters_path, notice: t("flash.created", model: Remitter.model_name.human)
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@remitter)
      if @remitter.update(remitter_params)
        audit!("remitter.updated", @remitter, before: before)
        redirect_to admin_remitters_path, notice: t("flash.updated", model: Remitter.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      before = Audit::Snapshot.of(@remitter)
      if @remitter.destroy
        audit!("remitter.destroyed", @remitter, before: before)
        redirect_to admin_remitters_path, notice: t("flash.destroyed", model: Remitter.model_name.human), status: :see_other
      else
        redirect_to admin_remitters_path, alert: @remitter.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private

    def set_remitter
      @remitter = Remitter.find(params[:id])
    end

    def remitter_params
      params.require(:remitter).permit(:name, :excel_key, :telegram_user_id, :telegram_username, :active)
    end
  end
end
