module Maintenance
  # Nightly (config/recurring.yml): deletes project packet zips past their last day, the
  # Project::PACKET_KEPT_FOR (7th) day after the day they were built (Project#packet_kept_until,
  # which the packet page shows). A zip is a full copy of a crew's files and can be rebuilt any
  # time from the packet page. Each build's PacketBuild row and its index.pdf are kept as the
  # record of what was sent; project.packet_built_at stays too, so the page can say the zip
  # expired.
  #
  # Goes by each attachment's own date, so a packet rebuilt while this runs is never touched.
  class PurgeOldPacketsJob < ApplicationJob
    queue_as :default

    # Returns the number of zips queued for purging.
    def perform
      count = 0
      ActiveStorage::Attachment.where(record_type: Project.name, name: "packet", created_at: ...Project.packet_purge_cutoff)
        .includes(:record, :blob).find_each do |attachment|
          attachment.purge_later
          count += 1
        end
      count
    end
  end
end
