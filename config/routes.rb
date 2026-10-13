require "sidekiq/web"

Rails.application.routes.draw do
  devise_for :users, skip: [ :registrations ]

  root to: redirect("/admin")

  namespace :admin do
    root "dashboard#index"

    resources :messages, only: [ :index, :show ]
    resources :transactions, only: [ :index, :show, :edit, :update ] do
      member do
        post :include_excluded
        post :approve
        post :hold
        post :reject
        post :reprocess
      end
    end

    # The OCR review queue; ids are transaction ids.
    resources :reviews, only: [ :index, :show, :update ]
    resources :bill_images, only: [ :show ]
    resources :bill_albums, only: [ :index, :show ]
    resources :bill_uploads, only: [ :new, :create ]
    # Remitters' transfers ("đi tiền"), reviewed apart from transactions.
    resources :remitter_transfers, only: [ :index, :show, :update ] do
      member { post :write }
    end

    resources :dealers
    resources :remitters, except: [ :show ]
    resources :transfer_codes, except: [ :show ]
    resources :telegram_chats do
      member { post :process_stored }
    end
    resources :merchants do
      resources :merchant_aliases, only: [ :create, :edit, :update, :destroy ]
    end
    resources :fee_rules
    resources :card_types, except: [ :show ]
    resources :excel_exports, only: [ :index, :new, :create, :show ] do
      member { get :download }
    end
    resources :audit_logs, only: [ :index, :show ]
    resources :users, except: [ :show ] do
      member { post :send_reset_password }
    end
    resources :roles, only: [ :index, :create, :destroy ] do
      collection { patch :grants }
    end
    resource :settings, only: [ :show, :update ] do
      post :check_r2
      patch :telegram_token
      patch :spreadsheet
      patch :tuning
      post :telegram_webhook
    end

    scope "settings", as: "settings" do
      get "organization/dealers", to: "dealers#index", as: :organization_dealers
      get "organization/telegram-chats", to: "telegram_chats#index", as: :organization_telegram_chats
      get "organization/merchants", to: "merchants#index", as: :organization_merchants
      get "organization/remitters", to: "remitters#index", as: :organization_remitters
      get "organization/transfer-codes", to: "transfer_codes#index", as: :organization_transfer_codes
      get "fees/rules", to: "fee_rules#index", as: :fees_rules
      get "fees/card-types", to: "card_types#index", as: :fees_card_types
      get "system/users", to: "users#index", as: :system_users
      get "system/roles", to: "roles#index", as: :system_roles
      get "system/audit-logs", to: "audit_logs#index", as: :system_audit_logs
    end

    authenticate :user, ->(user) { user.admin? && user.active? } do
      mount Sidekiq::Web => "/sidekiq"
    end
  end

  namespace :webhooks do
    post :telegram, to: "telegram#create"
  end

  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?

  get "/health", to: "health#show"
  get "/up", to: "rails/health#show", as: :rails_health_check
  # Public board so người đi tiền can copy a transfer code. Not under admin auth.
  get "/ma", to: "runner_codes#index", as: :runner_codes
end
