# Preview all emails at http://localhost:3000/rails/mailers/import_mailer
# Uses the latest finished batch when there is one, otherwise an unsaved sample batch
# (no links to it), so it renders on an empty database. Nothing is written.
class ImportMailerPreview < ActionMailer::Preview
  # Preview this email at http://localhost:3000/rails/mailers/import_mailer/summary
  def summary
    batch = ImportBatch.finished.includes(:uploaded_by).recent.first || sample_batch
    ImportMailer.with(batch: batch).summary
  end

  # Preview this email at http://localhost:3000/rails/mailers/import_mailer/summary_all_done
  def summary_all_done
    ImportMailer.with(batch: sample_batch(review: 0)).summary
  end

  # Preview this email at http://localhost:3000/rails/mailers/import_mailer/summary_failed
  def summary_failed
    batch = sample_batch(review: 0, accepted: 0, duplicate: 0, rejected: 0, failed: 1, status: :failed,
      error_message: "Couldn't open crew.zip: the file is not a zip.")
    ImportMailer.with(batch: batch).summary
  end

  private
    def sample_batch(accepted: 9, review: 3, duplicate: 1, rejected: 1, failed: 0, status: nil, error_message: nil)
      counts = ImportItem.statuses.keys.index_with(0)
        .merge("accepted" => accepted, "needs_review" => review, "duplicate" => duplicate, "rejected" => rejected, "failed" => failed)
      items = counts.values.sum
      batch = ImportBatch.new(uploaded_by: uploader, status: status || (review.positive? ? :needs_review : :completed),
        files_count: items, items_count: items, accepted_count: accepted, review_count: review, error_count: failed,
        error_message: error_message, created_at: Time.current)
      batch.status_counts = counts
      batch
    end

    def uploader
      User.where(role: %i[admin manager]).order(:id).first ||
        User.new(name: "Pat Example", email_address: "pat@example.com", role: :manager)
    end
end
