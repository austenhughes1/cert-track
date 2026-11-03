require "test_helper"

class PacketsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:tower_2417)
    # The test environment uses :null_store; the building state needs a real cache.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "requires sign-in to view or build" do
    get project_packet_path(@project)
    assert_redirected_to new_session_path

    assert_no_enqueued_jobs(only: Compliance::PacketJob) { post project_packet_path(@project) }
    assert_redirected_to new_session_path
  end

  test "shows the empty state and a build button when no packet exists" do
    sign_in_as users(:viewer)

    get project_packet_path(@project)

    assert_response :success
    assert_select "title", /Packet · 2417/
    assert_select "#packet_status[data-state=none]"
    assert_select "button", text: "Build packet"
    assert_select "[data-controller=auto-refresh]", count: 0
    assert_select "#packet_gap_count", text: Compliance::ProjectReport.new(@project).gaps.size.to_s
  end

  test "viewer can build a packet; the page polls while building" do
    sign_in_as users(:viewer)

    assert_enqueued_with(job: Compliance::PacketJob, args: [ @project ]) do
      post project_packet_path(@project)
    end
    assert_redirected_to project_packet_path(@project)

    follow_redirect!
    assert_select "#packet_status[data-state=building]"
    assert_select "#packet_status[data-controller=auto-refresh][data-auto-refresh-interval-value='3000']"
    assert_select "button", text: /Build packet|Rebuild packet/, count: 0
  end

  test "a second request while building does not enqueue another job" do
    sign_in_as users(:manager)
    Compliance::PacketJob.request(@project)

    assert_no_enqueued_jobs(only: Compliance::PacketJob) { post project_packet_path(@project) }
    assert_redirected_to project_packet_path(@project)
    assert_equal "The packet is already being built.", flash[:notice]
  end

  test "shows the download link, build time and rebuild button once ready" do
    freeze_time # blob links expire (urls_expire_in): the page's link and the expected one are minted at the same time
    certificates(:juan_osha30).files.attach(io: StringIO.new("%PDF-1.4\n"), filename: "osha.pdf", content_type: "application/pdf")
    Compliance::PacketJob.request(@project)
    perform_enqueued_jobs(only: Compliance::PacketJob)
    sign_in_as users(:viewer)

    get project_packet_path(@project)

    @project.reload
    assert_select "#packet_status[data-state=ready]"
    assert_select "a[href=?]", rails_blob_path(@project.packet, disposition: "attachment"), text: "Download zip"
    assert_select "time[datetime=?]", @project.packet_built_at.iso8601
    assert_select "button", text: "Rebuild packet"
    assert_select "[data-controller=auto-refresh]", count: 0
    assert_select "#packet_file_count", text: "1"

    get rails_blob_path(@project.packet, disposition: "attachment")
    assert_response :redirect
  end

  test "shows a failure notice after a failed build" do
    sign_in_as users(:viewer)
    Compliance::PacketJob.write_state(@project, "failed", expires_in: 1.hour)

    get project_packet_path(@project)

    assert_select "#packet_status[data-state=none]"
    assert_select "[role=alert]", text: /The last build failed/
    assert_select "button", text: "Build packet"
  end
end
