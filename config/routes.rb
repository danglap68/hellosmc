require "sidekiq/web"

Rails.application.routes.draw do
  devise_for :users, skip: [ :registrations ]

  root to: redirect("/admin")

  namespace :admin do
    root "dashboard#index"

    resources :transactions, only: [ :index, :show, :edit, :update ] do
      member do
        post :approve
        post :hold
        post :reject
        post :reprocess
      end
    end

    # The OCR review queue; ids are transaction ids.
    resources :reviews, only: [ :index, :show, :update ]
    resources :bill_images, only: [ :show ]
    resources :bill_uploads, only: [ :new, :create ]

    resources :dealers
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
    resource :settings, only: [ :show, :update ] do
      post :check_r2
      patch :telegram_token
      post :telegram_webhook
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
end
