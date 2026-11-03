require "test_helper"

class ImportItemTest < ActiveSupport::TestCase
  def build(**attrs)
    ImportItem.new({ import_batch: import_batches(:march_batch), sha256: "a" * 64 }.merge(attrs))
  end

  test "statuses and default" do
    assert_equal %w[pending extracting needs_review accepted rejected duplicate failed], ImportItem.statuses.keys
    assert build.pending?
  end

  test "validates sha256, page_range and confidence" do
    assert_not build(sha256: nil).valid?
    assert_not build(sha256: "xyz").valid?
    assert build(sha256: " #{"AB" * 32} ").tap(&:validate).sha256 == "ab" * 32
    assert_not build(page_range: "1-a").valid?
    assert build(page_range: "3").valid?
    assert build(page_range: " ").tap(&:validate).page_range.nil?
    assert_not build(confidence: 1.5).valid?
    assert build(confidence: 0.85).valid?
  end

  test "original_for finds the first non-duplicate item for a file and page range" do
    sha = import_items(:accepted_li_flagger).sha256
    assert_equal import_items(:accepted_li_flagger), ImportItem.original_for(sha, "1")
    assert_equal import_items(:review_juan_first_aid), ImportItem.original_for(sha.upcase, "2")
    assert_nil ImportItem.original_for(sha, "3")
    assert_nil ImportItem.original_for("b" * 64, nil)
  end

  test "original_for matches nil page ranges and skips failed items" do
    failed = build(sha256: "c" * 64, status: :failed).tap(&:save!)
    assert_nil ImportItem.original_for("c" * 64, nil)
    ok = build(sha256: "c" * 64).tap(&:save!)
    assert_equal ok, ImportItem.original_for("c" * 64, "")
    assert failed.persisted?
  end

  test "duplicates are stored and linked" do
    original = import_items(:accepted_li_flagger)
    copy = build(sha256: original.sha256, page_range: "1")
    copy.save!
    copy.mark_duplicate_of!(original)

    assert copy.reload.duplicate?
    assert_equal original, copy.duplicate_of
    assert_includes original.duplicates, copy
  end

  test "terminal and unfinished scopes" do
    assert_equal %w[accepted_li_flagger duplicate_li_flagger].map { import_items(_1) }.sort_by(&:id), ImportItem.terminal.order(:id).to_a
    assert_equal [ import_items(:review_juan_first_aid) ], ImportItem.unfinished.to_a
    assert_equal [ import_items(:review_juan_first_aid) ], ImportItem.review_queue.to_a
    assert import_items(:accepted_li_flagger).terminal?
  end

  test "pages" do
    assert_equal [ 1, 2, 3 ], build(page_range: "1-3").pages
    assert_equal [ 2 ], build(page_range: "2").pages
    assert_equal [], build.pages
  end

  test "proposed_certificate_number is encrypted" do
    assert_equal "FL-55501", import_items(:accepted_li_flagger).proposed_certificate_number
    assert_equal import_items(:accepted_li_flagger), ImportItem.find_by(proposed_certificate_number: "FL-55501")
  end

  test "associations" do
    item = import_items(:accepted_li_flagger)
    assert_equal certificates(:li_flagger), item.certificate
    assert_equal [ certificates(:li_flagger) ], item.created_certificates.to_a
    assert_equal crew_members(:li_chen), item.matched_crew_member
    assert_equal certificate_types(:flagger), item.matched_certificate_type
    assert_equal users(:manager), item.reviewed_by
    assert_equal({ "pages" => [ 1 ], "holder_name" => "LI CHEN", "certificate_type_code" => "FLAGGER", "confidence" => 0.93 }, item.extraction)
  end

  test "has an attached file" do
    item = build
    item.file.attach(io: StringIO.new("%PDF"), filename: "page1.pdf", content_type: "application/pdf")
    item.save!
    assert item.file.attached?
  end

  test "purge_stale_extractions! clears old accepted and rejected text only" do
    accepted = import_items(:accepted_li_flagger)
    review = import_items(:review_juan_first_aid)
    accepted.update_columns(reviewed_at: 31.days.ago)
    review.update_columns(updated_at: 40.days.ago)

    assert_equal [ accepted ], ImportItem.purgeable.to_a
    assert_equal 1, ImportItem.purge_stale_extractions!
    assert_nil accepted.reload.extracted_text
    assert_nil accepted.extraction
    assert_not_nil review.reload.extracted_text
    assert_empty ImportItem.purgeable
  end

  test "destroying an original nullifies its duplicates" do
    original = import_items(:accepted_li_flagger)
    original.destroy!
    assert_nil import_items(:duplicate_li_flagger).reload.duplicate_of_id
    assert_nil certificates(:li_flagger).reload.import_item_id
  end
end
