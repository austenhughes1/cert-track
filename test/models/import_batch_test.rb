require "test_helper"

class ImportBatchTest < ActiveSupport::TestCase
  test "defaults to receiving with zero counts" do
    batch = ImportBatch.create!(uploaded_by: users(:manager))
    assert batch.receiving?
    assert_equal 0, batch.items_count
  end

  test "requires an uploader" do
    assert_not ImportBatch.new.valid?
  end

  test "status enum" do
    assert_equal %w[receiving processing needs_review completed failed], ImportBatch.statuses.keys
    assert_includes ImportBatch.needs_review, import_batches(:march_batch)
  end

  test "refresh_counts! recomputes counters" do
    batch = import_batches(:march_batch)
    batch.update_columns(items_count: 0, accepted_count: 0, review_count: 0)
    batch.import_items.create!(sha256: "f" * 64, status: :failed, error_message: "OCR failed")

    batch.refresh_counts!
    assert_equal [ 4, 1, 1, 1 ], [ batch.items_count, batch.accepted_count, batch.review_count, batch.error_count ]
    assert_equal 1, batch.duplicate_count
  end

  test "all_items_terminal?" do
    batch = import_batches(:march_batch)
    assert_not batch.all_items_terminal?
    import_items(:review_juan_first_aid).rejected!
    assert batch.all_items_terminal?
    assert_not ImportBatch.create!(uploaded_by: users(:admin)).all_items_terminal?
  end

  test "uploads attachment" do
    batch = ImportBatch.create!(uploaded_by: users(:manager))
    batch.uploads.attach(io: StringIO.new("PK"), filename: "certs.zip", content_type: "application/zip")
    assert_equal 1, batch.uploads.count
  end

  test "destroying a batch removes its items and keeps certificates" do
    batch = import_batches(:march_batch)
    batch.destroy!
    assert_equal 0, ImportItem.where(import_batch_id: batch.id).count
    assert_nil certificates(:li_flagger).reload.import_item_id
  end
end
