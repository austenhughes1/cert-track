# Role checks without a gem (docs/PLAN.md: "a small authorize! helper").
#
#   class CrewMembersController < ApplicationController
#     require_role :editor, except: %i[index show]   # admins and managers write
#   end
#
#   authorize! :admin   # inside an action, for one-off checks
#
# Levels: :admin (admins only), :editor (admins and managers), :viewer (any signed-in user).
module Authorization
  extend ActiveSupport::Concern

  class NotAuthorized < StandardError; end

  LEVELS = {
    admin: ->(user) { user.admin? },
    editor: ->(user) { user.editor? },
    viewer: ->(user) { true }
  }.freeze

  included do
    rescue_from NotAuthorized, with: :render_forbidden
    helper_method :can?
  end

  class_methods do
    def require_role(level, **options)
      before_action(**options) { authorize!(level) }
    end
  end

  private
    def can?(level)
      user = Current.user
      user.present? && LEVELS.fetch(level).call(user)
    end

    def authorize!(level)
      raise NotAuthorized unless can?(level)
    end

    def render_forbidden
      respond_to do |format|
        format.html { render "errors/forbidden", status: :forbidden }
        format.any { head :forbidden }
      end
    end
end
