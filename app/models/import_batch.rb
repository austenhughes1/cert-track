# One drop of files and zips on the Imports screen.
#
# Lifecycle: receiving (uploaded, waiting for Imports::ExpandJob) -> processing (items
# being read) -> needs_review | completed | failed. check_completion! moves it along after
# every item step and sends the uploader one summary email the first time it finishes.
class ImportBatch < ApplicationRecord
  FINISHED_STATUSES = %w[needs_review completed failed].freeze

  enum :status, { receiving: 0, processing: 1, needs_review: 2, completed: 3, failed: 4 },
    default: :receiving, validate: true

  belongs_to :uploaded_by, class_name: "User"
  has_many :import_items, dependent: :destroy
  has_many_attached :uploads # raw files and zips as dropped; deleted once unpacked (discard_uploads!)

  validates :files_count, :items_count, :accepted_count, :review_count, :error_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :in_progress, -> { where(status: %i[receiving processing]) }
  scope :finished, -> { where(status: FINISHED_STATUSES) }

  class << self
    # Loads progress for many batches in two queries (no N+1 on a list page); each
    # batch's #progress and #status_counts then use it until reload.
    def preload_progress(batches, now: Time.current)
      batches = Array(batches)
      ids = batches.map(&:id)
      counts = ImportItem.where(import_batch_id: ids).group(:import_batch_id, :status).count
      waiting = ImportItem.waiting_for_budget(now).where(import_batch_id: ids).group(:import_batch_id).count

      batches.each do |batch|
        batch.status_counts = ImportItem.statuses.keys.index_with { |status| counts.fetch([ batch.id, status ], 0) }
        batch.waiting_for_budget_count = waiting.fetch(batch.id, 0)
      end
    end

    # Deletes the uploads still held by batches created more than ImportItem::PURGE_AFTER (30
    # days) ago: Imports::ExpandJob keeps them when unpacking stopped part way (an unexpected
    # error), and a worker can die between unpacking and deleting them. Nightly, from
    # Maintenance::PurgeImportExtractionsJob. Returns the number of uploads deleted.
    def purge_stale_uploads!(now: Time.current)
      stale = where(created_at: ...(now - ImportItem::PURGE_AFTER))
      Imports::FileCleanup.delete(
        ActiveStorage::Attachment.where(record_type: polymorphic_name, name: "uploads", record_id: stale.select(:id))
      )
    end
  end

  # Preloaded values (see preload_progress); cleared on reload.
  attr_writer :status_counts, :waiting_for_budget_count

  def reload(*)
    @status_counts = @waiting_for_budget_count = nil
    super
  end

  # { "pending" => 0, "extracting" => 0, "needs_review" => 1, ..., "failed" => 0 }: every
  # ImportItem status, counted from the items (not the stored counters).
  def status_counts
    return @status_counts if @status_counts
    return ImportItem.statuses.keys.index_with(0) if new_record?

    counts = import_items.group(:status).count
    ImportItem.statuses.keys.index_with { |status| counts.fetch(status, 0) }
  end

  def waiting_for_budget_count(now = Time.current)
    return @waiting_for_budget_count if @waiting_for_budget_count
    return 0 if new_record?

    import_items.waiting_for_budget(now).count
  end

  # Recomputes the stored counters from import_items.
  def refresh_counts!
    update!(counter_attributes(fresh_status_counts))
  end

  def duplicate_count
    status_counts.fetch("duplicate")
  end

  def rejected_count
    status_counts.fetch("rejected")
  end

  # For the progress UI. Symbol keys: every item status (:pending ... :failed), plus
  #   total:              items in the batch
  #   processed:          items past text extraction and AI (total - pending - extracting)
  #   percent:            processed as a whole percentage of total (0 when there are no items)
  #   waiting_for_budget: unfinished items parked until the AI allocation resets
  def progress(now: Time.current)
    counts = status_counts.transform_keys(&:to_sym)
    total = counts.values.sum
    processed = total - counts.values_at(*ImportItem::PIPELINE_STATUSES.map(&:to_sym)).sum
    counts.merge(
      total: total,
      processed: processed,
      percent: total.zero? ? 0 : (processed * 100 / total),
      waiting_for_budget: waiting_for_budget_count(now)
    )
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end

  # Deletes the raw uploads once Imports::ExpandJob has turned every entry into an item: the
  # items keep what was found in them. A single-file upload's blob is reused as its item's
  # file, so only the upload's attachment goes and the file stays. Returns the number deleted.
  def discard_uploads!
    Imports::FileCleanup.delete(uploads_attachments).tap { uploads_attachments.reset }
  end

  # True once there is at least one item and every item is accepted, rejected, duplicate or failed.
  def all_items_terminal?
    import_items.exists? && !import_items.unfinished.exists?
  end

  # Call after any item changes status (pipeline step or review action). Refreshes the
  # counters and sets the status from the items:
  #   any item pending/extracting -> processing
  #   else any needs_review       -> needs_review
  #   else every item failed (or there are none) -> failed
  #   else                        -> completed
  # A receiving batch (not unpacked yet) is left alone. The first time the batch
  # finishes, the uploader gets ImportMailer#summary, exactly once even when callers race
  # or the batch goes back to processing later (Imports::Reread). The send counts against
  # the daily email cap (Imports::SummaryDeliveryJob).
  def check_completion!
    finished = with_lock do
      next false if receiving?

      counts = fresh_status_counts
      update!(counter_attributes(counts).merge(status: status_from(counts)))
      finished?
    end

    deliver_summary_once if finished
    self
  end

  private
    def fresh_status_counts
      @status_counts = nil
      status_counts
    end

    def counter_attributes(counts)
      { items_count: counts.values.sum, accepted_count: counts.fetch("accepted"),
        review_count: counts.fetch("needs_review"), error_count: counts.fetch("failed") }
    end

    def status_from(counts)
      total = counts.values.sum
      if counts.values_at(*ImportItem::PIPELINE_STATUSES).sum.positive? then :processing
      elsif counts.fetch("needs_review").positive? then :needs_review
      elsif total.zero? || counts.fetch("failed") == total then :failed
      else :completed
      end
    end

    # The summary_sent_at guard is one atomic UPDATE, so only one caller ever wins.
    def deliver_summary_once
      sent_at = Time.current
      return false unless self.class.where(id: id, summary_sent_at: nil).update_all(summary_sent_at: sent_at) == 1

      self.summary_sent_at = sent_at
      clear_attribute_changes([ :summary_sent_at ])
      ImportMailer.with(batch: self).summary.deliver_later
      true
    end
end
