class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Crews use whatever phone they have, and an older one should get a plainer page, not a refusal
  # (:modern turns away anything below iOS 17.2). Only Internet Explorer can't run it at all.
  allow_browser versions: { ie: false }

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
end
