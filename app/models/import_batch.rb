# One drop of files and zips on the Imports screen.
class ImportBatch < ApplicationRecord
  enum :status, { receiving: 0, processing: 1, needs_review: 2, completed: 3, failed: 4 },
    default: :receiving, validate: true

  belongs_to :uploaded_by, class_name: "User"
  has_many :import_items, dependent: :destroy
  has_many_attached :uploads # raw files and zips as dropped

  validates :files_count, :items_count, :accepted_count, :review_count, :error_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # Recomputes the item counters from import_items.
  def refresh_counts!
    counts = import_items.group(:status).count
    update!(items_count: counts.values.sum,
      accepted_count: counts.fetch("accepted", 0),
      review_count: counts.fetch("needs_review", 0),
      error_count: counts.fetch("failed", 0))
  end

  def duplicate_count
    import_items.duplicate.count
  end

  # True once there is at least one item and every item is accepted, rejected, duplicate or failed.
  def all_items_terminal?
    import_items.exists? && !import_items.unfinished.exists?
  end
end
