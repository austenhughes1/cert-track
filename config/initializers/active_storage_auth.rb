# Locks down Active Storage's own controllers (docs/PLAN.md, "Security and privacy").
# config/initializers/active_storage.rb already includes Authentication in
# ActiveStorage::BaseController; this file (loaded after it) tightens four things:
#
# 1. Sign-in runs before anything else, so an anonymous request never looks up a blob or
#    generates a variant/PDF preview (those before_actions are declared in the subclasses).
# 2. Direct uploads need an editor (admin or manager). Viewers are read-only, so they
#    must not be able to create blobs either.
# 3. The proxy controllers mark responses private. Rails sends "public, immutable", and
#    a shared cache in front of the app (Thruster caches public responses) would then
#    hand a signed-in user's file to anyone.
# 4. Import files need an editor, like the import and review pages that link to them
#    (ImportFileAccess below): until a file is accepted it can be an unreviewed or rejected
#    scan with personal data on it, such as a CDL card. Viewers get 403.
#
# The signed links themselves expire too (urls_expire_in in active_storage.rb), so one
# copied from a page stops working.

# The blob redirect and proxy controllers (and the representation ones, before any variant
# or preview is made) answer 403 to a non-editor for a blob that only imports use:
# ImportItem#file or ImportBatch#uploads. An accepted file is its certificate's
# (Imports::Accept hands the blob over), so it opens for anyone signed in, like every
# certificate file. A blob attached to nothing (a direct upload not saved yet) is
# editors-only too. A variant or preview image is judged by the blob it was made from.
module ImportFileAccess
  IMPORT_RECORD_TYPES = %w[ImportItem ImportBatch].freeze
  MAX_DEPTH = 2 # a variant's or preview's blob -> the blob it was made from

  # True when nothing but imports uses the blobs (or the blobs they were made from).
  def self.editors_only?(blob_ids, depth = 0)
    sources = []
    ActiveStorage::Attachment.where(blob_id: blob_ids).pluck(:record_type, :record_id).each do |type, id|
      case type
      when *IMPORT_RECORD_TYPES then next
      when "ActiveStorage::Blob" then sources << id # a PDF or video preview image
      when "ActiveStorage::VariantRecord" then sources.concat(ActiveStorage::VariantRecord.where(id: id).pluck(:blob_id))
      else return false
      end
    end
    sources.empty? || depth >= MAX_DEPTH || editors_only?(sources.uniq, depth + 1)
  end

  private
    # ActiveStorage::SetBlob#set_blob, then the check, so nothing is served or processed first.
    def set_blob
      super
      return if performed? || @blob.nil? || Current.user&.editor?

      head :forbidden if ImportFileAccess.editors_only?([ @blob.id ])
    end
end

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

  [ ActiveStorage::Blobs::RedirectController, ActiveStorage::Blobs::ProxyController,
    ActiveStorage::Representations::RedirectController, ActiveStorage::Representations::ProxyController ].each do |controller|
    controller.prepend(ImportFileAccess)
  end
end
