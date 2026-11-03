# Locks down Active Storage's own controllers (docs/PLAN.md, "Security and privacy").
# config/initializers/active_storage.rb already includes Authentication in
# ActiveStorage::BaseController; this file (loaded after it) tightens three things:
#
# 1. Sign-in runs before anything else, so an anonymous request never looks up a blob or
#    generates a variant/PDF preview (those before_actions are declared in the subclasses).
# 2. Direct uploads need an editor (admin or manager). Viewers are read-only, so they
#    must not be able to create blobs either.
# 3. The proxy controllers mark responses private. Rails sends "public, immutable", and
#    a shared cache in front of the app (Thruster caches public responses) would then
#    hand a signed-in user's file to anyone.
Rails.application.config.to_prepare do
  ActiveStorage::BaseController.class_eval do
    include Authentication # no-op when active_storage.rb already did it

    prepend_before_action :require_authentication
  end

  ActiveStorage::DirectUploadsController.class_eval do
    include Authorization

    before_action { authorize!(:editor) }

    private
      # The direct-upload JS posts JSON; there is no app layout to render inside the engine.
      def render_forbidden
        head :forbidden
      end
  end

  [ ActiveStorage::Blobs::ProxyController, ActiveStorage::Representations::ProxyController ].each do |controller|
    controller.class_eval do
      private
        def http_cache_forever(public: false, &block)
          super(public: false, &block)
        end
    end
  end
end
