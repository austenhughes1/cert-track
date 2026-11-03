module Backups
  # Nightly encrypted pg_dump of the primary database to R2, keeping the newest 14
  # (config/recurring.yml). Failures raise so Solid Queue records them.
  class DatabaseJob < ApplicationJob
    queue_as :default

    def perform
      Backups::Create.new.call.key
    end
  end
end
