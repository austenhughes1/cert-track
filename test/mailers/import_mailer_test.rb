require "test_helper"
require_relative "previews/import_mailer_preview"

class ImportMailerTest < ActionMailer::TestCase
  setup do
    @batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing, files_count: 5)
  end

  test "summary goes to the uploader with every count" do
    add(:accepted, 2)
    add(:needs_review, 3)
    add(:duplicate)
    add(:rejected, rejection_reason: "Unsupported file type (text/plain): only PDF, JPG, PNG, HEIC and WEBP are read",
      original_filename: "crew.zip/notes.txt")
    @batch.refresh_counts!

    mail = summary
    assert_equal [ "manager@example.com" ], mail.to
    assert_equal "CertTrack import: 3 items need review", mail.subject
    assert mail.html_part.present? && mail.text_part.present?

    text = mail.text_part.body.to_s
    assert_includes text, "3 items from your import need review."
    assert_includes text, "You uploaded 5 files on #{@batch.created_at.strftime("%b %-d, %Y")}. CertTrack found 7 items in them."
    [ "Accepted:     2", "Needs review: 3", "Duplicates:   1", "Rejected:     1", "Failed:       0" ].each do |line|
      assert_includes text, line
    end
    assert_includes text, "- crew.zip/notes.txt: Unsupported file type (text/plain)"
    assert_includes text, "Review queue: http://example.com/imports/review"
    assert_includes text, "This batch: http://example.com/imports/#{@batch.id}"
    assert_includes text, "You receive this because you uploaded this import batch (manager@example.com)."

    html = mail.html_part.body.to_s
    assert_includes html, %(href="http://example.com/imports/review")
    assert_includes html, %(href="http://example.com/imports/#{@batch.id}")
    assert_includes html, "Open the review queue"
    assert_includes html, "crew.zip/notes.txt"
  end

  test "subject and heading when nothing needs review" do
    add(:accepted)
    @batch.update!(status: :completed)

    mail = summary
    assert_equal "CertTrack import finished", mail.subject
    assert_includes mail.text_part.body.to_s, "Your import is finished."
    assert_not_includes mail.text_part.body.to_s, "Review queue:"
    assert_not_includes mail.html_part.body.to_s, "Open the review queue"

    single = ImportBatch.create!(uploaded_by: users(:admin), status: :needs_review)
    single.import_items.create!(status: :needs_review, sha256: SecureRandom.hex(32))
    assert_equal "CertTrack import: 1 item needs review", ImportMailer.with(batch: single).summary.subject
  end

  test "a failed batch shows the batch error and each failure" do
    @batch.update!(status: :failed, error_message: "Stopped at the 2,000-file limit for one batch.")
    add(:failed, error_message: "pdftotext: the file is password-protected", original_filename: "locked.pdf")

    mail = summary
    assert_equal "CertTrack import failed", mail.subject
    text = mail.text_part.body.to_s
    assert_includes text, "Your import failed."
    assert_includes text, "Stopped at the 2,000-file limit for one batch."
    assert_includes text, "- locked.pdf: Failed: pdftotext: the file is password-protected"
    assert_includes mail.html_part.body.to_s, "Stopped at the 2,000-file limit for one batch."
  end

  test "lists at most ten problem files" do
    add(:rejected, 12, rejection_reason: "Unsafe path in zip (zip-slip guard): refused")

    text = summary.text_part.body.to_s
    assert_equal 10, text.scan("zip-slip guard").size
    assert_includes text, "and 2 more on the batch page."
  end

  test "previews render the latest finished batch, or sample data" do
    preview = ImportMailerPreview.new
    assert_equal "CertTrack import: 1 item needs review", preview.summary.subject # the march_batch fixture
    assert_equal "CertTrack import finished", preview.summary_all_done.subject
    assert_equal "CertTrack import failed", preview.summary_failed.subject

    sample = preview.summary_all_done
    assert_includes sample.text_part.body.to_s, "Accepted:     9"
    assert_not_includes sample.text_part.body.to_s, "This batch:"
    assert_no_difference -> { ImportBatch.count } do
      preview.summary_failed.html_part.body.to_s
    end
  end

  private
    def summary
      ImportMailer.with(batch: @batch).summary
    end

    def add(status, count = 1, **attributes)
      count.times.map do |n|
        @batch.import_items.create!({ status: status, sha256: SecureRandom.hex(32), original_filename: "file#{n}.pdf" }.merge(attributes))
      end
    end
end
