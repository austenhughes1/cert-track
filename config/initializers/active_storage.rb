# Certificate files carry personal data (docs/PLAN.md, "Security and privacy"): the R2 bucket is
# private and every file is served by redirecting through Rails to a presigned URL. Those service
# URLs must expire within 5 minutes, in every environment.
Rails.application.config.active_storage.service_urls_expire_in = 5.minutes

# url_for(attachment) and friends go through the redirect controller, never proxy file bytes.
Rails.application.config.active_storage.resolve_model_to_route = :rails_storage_redirect

# Active Storage's own controllers (blob/representation redirects, direct uploads, the disk
# service) inherit from ActionController::Base, not ApplicationController, so they would serve
# files and accept uploads without a session. Require sign-in for all of them.
Rails.application.config.to_prepare do
  ActiveStorage::BaseController.class_eval do
    include Authentication

    # Active Storage is an isolated engine, so the app's route helpers live behind main_app.
    delegate :new_session_path, to: :main_app, private: true
  end
end
