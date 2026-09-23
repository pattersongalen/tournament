Rails.application.routes.draw do
  resource :session, only: [:new, :create, :destroy] do
    collection do
      get :consume
      get :check_email
      get :code
      post :code, action: :submit_code
    end
  end
  # When the admin subdomain is hit (admin.<APP_HOST>), land directly on
  # /admin instead of the PWA home. Same app, just a host-driven shortcut.
  app_host = ENV.fetch("APP_HOST", "localhost")
  unless app_host == "localhost"
    constraints(host: "admin.#{app_host}") do
      root to: redirect("/admin"), as: :admin_host_root
    end
  end
  root "home#index"

  get "/manifest.webmanifest", to: "pwa#manifest"
  get "/service-worker.js", to: "pwa#service_worker"
  get "/offline", to: "pwa#offline"
  get "/recover", to: "recover#index"

  namespace :organizers do
    resources :tournaments do
      member do
        post   :draw
        post   :link,   to: "tournament_links#create"
        delete :link,   to: "tournament_links#destroy"
      end
      resources :tournament_entries, only: [:create, :update, :destroy] do
        resources :tournament_entry_members, only: [:create, :destroy] do
          collection { post :same_as_last_week }
        end
      end
      resources :tournament_judges,   only: [:create, :destroy]
      resources :tournament_deputies, only: [:create, :destroy]
      resources :boats, only: [] do
        member { post :enter }
      end
    end
    resources :boats, only: [:index, :create, :update, :destroy] do
      # #destroy retires (soft); #purge is the real delete. The names read
      # backwards, but #destroy shipped as Retire and is what the retire
      # button, its tests and both namespaces already point at.
      member do
        post   :restore
        delete :purge
      end
    end
    resources :members, only: [:index, :new, :create, :destroy] do
      member do
        post :reactivate
        post :issue_code
        get  :code
      end
    end
    resources :catches, only: [:index, :show, :update]
    resources :tournament_templates do
      member { post :clone }
      resource :league_night, only: [:new, :create], controller: "league_nights"
    end
  end

  namespace :admin do
    root to: "dashboards#index"
    resources :clubs, only: [ :index, :show, :new, :create, :edit, :update ] do
      scope module: :clubs do
        resources :members, only: [:index, :new, :create, :edit, :update] do
          member do
            post :issue_code
            get  :code
          end
        end
        resources :tournaments, only: [:index, :show]
        resources :catches, only: [:index]
        resources :tournament_templates, only: [:index, :show]
        resources :rules, only: [:index, :show] do
          collection { get :history }
        end
        resource :banner, only: [:edit, :update], controller: "banners"
        resource :season_points, only: [:edit, :update], controller: "season_points"
      end
    end
    resources :tournaments do
      member do
        get    :results
        post   :link,   to: "tournament_links#create"
        delete :link,   to: "tournament_links#destroy"
      end
      resources :tournament_entries, only: [:create, :update, :destroy] do
        resources :tournament_entry_members, only: [:create, :destroy] do
          collection { post :same_as_last_week }
        end
      end
      resources :tournament_judges,  only: [:create, :destroy]
      resources :tournament_deputies, only: [:create, :destroy]
      resources :boats, only: [] do
        member { post :enter }
      end
    end
    resources :boats, only: [:index, :create, :update, :destroy] do
      # #destroy retires (soft); #purge is the real delete. The names read
      # backwards, but #destroy shipped as Retire and is what the retire
      # button, its tests and both namespaces already point at.
      member do
        post   :restore
        delete :purge
      end
    end
    resources :members, only: [:index, :new, :create, :edit, :update, :destroy] do
      member do
        patch  :role
        post   :reactivate
        delete :purge
        post   :issue_code
        get    :code
      end
    end
    resources :catches, only: [:index, :show, :update]
    resources :tournament_templates do
      member { post :clone }
      resource :league_night, only: [:new, :create], controller: "league_nights"
    end
    resources :rules, only: [ :index, :new, :create, :show ] do
      collection do
        get  :history
        post :set_active_season
      end
    end
  end

  resources :tournaments, only: [:index, :show] do
    collection { get :archived }
    get :bingo_card, on: :member
    scope module: :tournaments do
      resources :catches, only: [:show]
    end
  end
  resources :catches, only: [:index, :new, :create, :show, :update] do
    collection do
      get :map
      get :select_teammate
      get :select_species
    end
    member do
      patch :reference_photo
    end
  end

  namespace :judges do
    resources :tournaments, only: [] do
      resources :catches, only: [:index, :show] do
        resource :review,          only: [:create]
        resource :manual_override, only: [:new, :create]
        member do
          patch :geofence_override
          patch :correct_location
          patch :reinstate
        end
      end
    end
  end

  namespace :api do
    get "version", to: "version#show"
    resource :session, only: [:show], controller: "sessions"
    resources :catches, only: [:create]
    post   "push_subscriptions", to: "push_subscriptions#create"
    post   "push_subscriptions/refresh", to: "push_subscriptions#refresh"
    delete "push_subscriptions", to: "push_subscriptions#destroy"
  end

  get "season-points",             to: "season_points#show",        as: :season_points
  get "season-points/tournaments", to: "season_points#tournaments", as: :season_points_tournaments

  get "/pre_trip", to: "pre_trip#show", as: :pre_trip
  get "/rules", to: "rules#show", as: :rules
  patch "/me", to: "users#update", as: :me

  resource :notification_settings, only: [:show], controller: :notification_settings do
    collection do
      post :snooze
      post :unmute
      post :mute_tournament
      post :unmute_tournament
    end
  end
end
