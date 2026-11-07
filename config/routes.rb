Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # --- Auth and users (invite-only; no public sign-up) ---
  resource :session, only: %i[new create destroy]
  resources :passwords, param: :token, only: %i[new create edit update]
  resources :users, except: :show do
    post :resend_invite, on: :member
    post :send_test_digest, on: :collection # Phase 2
  end

  root "dashboard#show"

  # --- Crew ---
  resources :crew_roles, except: :show
  resources :crew_members do
    resources :certificates, except: :index do
      delete "files", action: :remove_file, on: :member, as: :remove_file # param: attachment_id
      # Phase 3b: a person's authenticity result (PATCH) and "Check again" (POST recheck)
      resource :authenticity, only: :update, controller: "authenticity_checks" do
        post :recheck
      end
    end
  end

  # --- Certificate types ---
  resources :certificate_types, except: :show do
    patch :move, on: :member # params: direction=up|down, status=list filter
  end
  # Who issues certificates and how each is verified (Phase 3b)
  resources :certificate_issuers, except: :show
  # Current certificates confirmed fake, flagged for review or needing a check (Phase 3b)
  resource :verification, only: :show, controller: "verification"

  # --- Projects, requirements, assignments, compliance ---
  resources :projects do
    resource :requirements, only: %i[edit update], controller: "project_requirements" do
      post :copy
    end
    resources :assignments, only: %i[index create update destroy], controller: "project_assignments"
    resource :compliance, only: :show, controller: "compliance" # /projects/:project_id/compliance(.csv)
    resource :packet, only: %i[show create], controller: "packets"
  end

  # --- Bulk import (Phase 3) ---
  # The review queue is declared before resources :imports so /imports/review isn't read as imports#show.
  scope "imports" do
    resources :review, controller: "import_reviews", as: :import_reviews, only: %i[index show update] do
      collection { post :accept_all }
      member do
        post :accept
        post :reject
        post :skip
        post :create_crew_member
        post :merge
        post :reread
        post :check # the authenticity panel: save the edits, then record a result or check again (Phase 3b)
      end
    end
    # Phase 3b: the review screen's authenticity panel (import_review_authenticity_path(item))
    scope "review/:import_item_id", as: :import_review do
      resource :authenticity, only: :update, controller: "authenticity_checks" do
        post :recheck
      end
    end
  end
  resources :imports, only: %i[index create show]

  # --- Ask box (Phase 4a) ---
  get "ask" => "ask#show", as: :ask

  # --- Admin tools ---
  mount MissionControl::Jobs::Engine, at: "/jobs"
end
