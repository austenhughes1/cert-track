# The email an uploader gets when their import batch finishes (pipeline step 11).
# Sent once per batch by ImportBatch#check_completion!. deliver_later goes through
# Imports::SummaryDeliveryJob, which keeps it under the 90/day email cap (held back to the
# next morning past it).
#
#   ImportMailer.with(batch:).summary
class ImportMailer < ApplicationMailer
  PROBLEM_LIMIT = 10

  self.delivery_job = Imports::SummaryDeliveryJob

  # [label, ImportItem status] in the order the summary lists them.
  COUNT_ROWS = [
    [ "Accepted", "accepted" ], [ "Needs review", "needs_review" ], [ "Duplicates", "duplicate" ],
    [ "Rejected", "rejected" ], [ "Failed", "failed" ]
  ].freeze

  helper do
    def import_count_style(status, count)
      color = if count.zero? then "#6b7280"
      else
        { "needs_review" => "#92400e", "failed" => "#991b1b", "accepted" => "#166534" }.fetch(status, "#111827")
      end
      "padding:4px 0;text-align:right;font-weight:600;color:#{color};"
    end

    def import_batch_url_or_nil(batch)
      import_url(batch) if batch.persisted?
    end
  end

  def summary
    @batch = params.fetch(:batch)
    @user = @batch.uploaded_by
    @counts = @batch.status_counts
    @review_count = @counts.fetch("needs_review")
    @problems = @batch.persisted? ? @batch.import_items.where(status: %i[rejected failed]).order(:id).limit(PROBLEM_LIMIT).to_a : []
    @problem_count = @counts.fetch("rejected") + @counts.fetch("failed")
    @uploaded_on = (@batch.created_at || Time.current).in_time_zone.strftime("%b %-d, %Y")

    mail to: email_address_with_name(@user.email_address, @user.name.to_s), subject: subject_line
  end

  private
    def subject_line
      if @review_count.positive?
        "CertTrack import: #{@review_count} #{"item".pluralize(@review_count)} #{@review_count == 1 ? "needs" : "need"} review"
      elsif @batch.failed?
        "CertTrack import failed"
      else
        "CertTrack import finished"
      end
    end
end
