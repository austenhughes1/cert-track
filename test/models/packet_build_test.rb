require "test_helper"

class PacketBuildTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @project = projects(:tower_2417)
  end

  test "is valid with a project, build time and file name; the builder is optional" do
    assert build_record.valid?
    assert build_record(built_by: nil).valid?
  end

  test "requires the build time and file name, and counts of zero or more" do
    record = build_record(built_at: nil, packet_filename: " ", certificate_count: -1, file_count: 1.5, gap_count: nil)

    assert_not record.valid?
    assert_equal %i[built_at certificate_count file_count gap_count packet_filename].sort, record.errors.attribute_names.sort
  end

  test "newest_first orders by build time, latest first" do
    older = build_record(built_at: 3.days.ago).tap(&:save!)
    newer = build_record(built_at: 1.hour.ago).tap(&:save!)

    assert_equal [ newer, older ], @project.packet_builds.newest_first.to_a
  end

  test "deleting the user who built it keeps the record without a builder" do
    user = User.create!(email_address: "builder@example.com", password: "password123")
    record = build_record(built_by: user).tap(&:save!)

    user.destroy!

    assert_nil record.reload.built_by_id
  end

  test "deleting the project deletes its builds and their index PDFs" do
    project = Project.create!(name: "Short job")
    record = PacketBuild.create!(project: project, built_at: Time.current, packet_filename: "x-packet.zip",
      index_pdf: { io: StringIO.new("%PDF-1.4\n"), filename: "x-index.pdf", content_type: "application/pdf" })
    blob = record.index_pdf.blob

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { project.destroy! }

    assert_not PacketBuild.exists?(record.id)
    assert_not ActiveStorage::Blob.exists?(blob.id)
  end

  private
    def build_record(**attributes)
      @project.packet_builds.new({ built_by: users(:manager), built_at: Time.current, packet_filename: "2417-packet-2026-11-04.zip",
        certificate_count: 3, file_count: 4, gap_count: 2 }.merge(attributes))
    end
end
