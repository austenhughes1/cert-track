# Base class for admin-only screens, including Mission Control Jobs at /jobs
# (see config/initializers/mission_control.rb).
class AdminController < ApplicationController
  require_role :admin

  private
    # Inside a mounted engine the app layout can't render (and the engine's own
    # layout needs state its skipped before_actions set up), so use a standalone page.
    def render_forbidden
      return super if _routes.equal?(Rails.application.routes)

      respond_to do |format|
        format.html { render "admin/forbidden", status: :forbidden, layout: false }
        format.any { head :forbidden }
      end
    end
end
