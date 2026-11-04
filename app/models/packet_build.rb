# A lasting record of one compliance packet build: when it was built and by whom, what it
# held, and a copy of that build's index.pdf. The zip itself (Project#packet) is deleted
# the night after its last day, 7 days after the build day (Project#packet_kept_until,
# Maintenance::PurgeOldPacketsJob); these rows and their index PDFs stay as the record of
# what was sent.
class PacketBuild < ApplicationRecord
  belongs_to :project
  belongs_to :built_by, class_name: "User", optional: true # nil once that user is deleted
  has_one_attached :index_pdf

  validates :built_at, :packet_filename, presence: true
  validates :certificate_count, :file_count, :gap_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :newest_first, -> { order(built_at: :desc, id: :desc) }
end
