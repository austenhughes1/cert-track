require "test_helper"

class Compliance::PacketJobTest < ActiveJob::TestCase
  setup do
    @project = projects(:tower_2417)
    # The test environment uses :null_store; build state needs a real cache.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "request marks the project as building and enqueues the job" do
    assert_enqueued_with(job: Compliance::PacketJob, args: [ @project ]) do
      Compliance::PacketJob.request(@project)
    end

    assert_equal "building", Compliance::PacketJob.state(@project)
    assert Compliance::PacketJob.building?(@project)
  end

  test "perform attaches the packet and clears the building state" do
    Compliance::PacketJob.request(@project)

    perform_enqueued_jobs

    @project.reload
    assert @project.packet.attached?
    assert_not_nil @project.packet_built_at
    assert_nil Compliance::PacketJob.state(@project)
    assert_nil Rails.cache.read(Compliance::PacketJob.state_key(@project))
  end

  test "a build that finished after the request is not building, even if the cache entry survives" do
    Compliance::PacketJob.request(@project)
    @project.update!(packet_built_at: 1.second.from_now)

    assert_nil Compliance::PacketJob.state(@project)
  end

  test "the building state times out in case a worker died" do
    Compliance::PacketJob.request(@project)

    travel Compliance::PacketJob::BUILD_TIMEOUT + 1.minute do
      assert_nil Compliance::PacketJob.state(@project)
    end
  end

  test "a failed build records the failed state and re-raises" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(io: StringIO.new("%PDF-1.4\n"), filename: "osha.pdf", content_type: "application/pdf")
    certificate.files.first.blob.service.delete(certificate.files.first.blob.key) # file gone from storage
    Compliance::PacketJob.request(@project)

    assert_raises(ActiveStorage::FileNotFoundError) { perform_enqueued_jobs }

    assert_equal "failed", Compliance::PacketJob.state(@project)
    assert_not @project.reload.packet.attached?
  end

  test "a later successful build clears a failure" do
    Compliance::PacketJob.write_state(@project, "failed", expires_in: 1.hour)

    Compliance::PacketJob.perform_now(@project)

    assert_nil Compliance::PacketJob.state(@project.reload)
  end

  test "state is nil when nothing was requested" do
    assert_nil Compliance::PacketJob.state(@project)
  end
end
