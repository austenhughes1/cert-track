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
    assert_select "#packet_builds", text: /No builds yet/
  end

  test "says which certificates a build leaves out: only those a person confirmed fake" do
    sign_in_as users(:viewer)
    get project_packet_path(@project)
    assert_select "#packet_excluded", count: 0
    certificates_before = css_select("#packet_certificate_count").text.to_i
    files_before = css_select("#packet_file_count").text.to_i
    gaps_before = css_select("#packet_gap_count").text.to_i

    certificates(:li_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:mismatch],
      authenticity_method: Authenticity::PERSON_METHOD)
    get project_packet_path(@project)

    assert_select "#packet_excluded", text: /1 certificate confirmed fake will be left out and listed in index\.pdf:.*Li Chen \(FLAGGER\)/m
    assert_select "#packet_certificate_count", text: (certificates_before - 1).to_s
    assert_select "#packet_gap_count", text: (gaps_before + 1).to_s
    assert_select "body", text: /flagged for review go in like any other/
    assert_select "#packet_excluded", text: /review/, count: 0

    # The same result from an automatic check only flags it for review: it still goes in.
    certificates(:li_flagger).update_columns(authenticity_method: "automatic:aha_ecards")
    get project_packet_path(@project)

    assert_select "#packet_excluded", count: 0
    assert_select "#packet_certificate_count", text: certificates_before.to_s
    assert_select "#packet_file_count", text: files_before.to_s
    assert_select "#packet_gap_count", text: gaps_before.to_s
  end

  test "certificates only flagged for review are all packaged" do
    sign_in_as users(:viewer)
    get project_packet_path(@project)
    certificates_before = css_select("#packet_certificate_count").text.to_i

    Certificate.current.update_all(authenticity_status: Certificate.authenticity_statuses[:suspicious],
      authenticity_method: Authenticity::PERSON_METHOD) # a person can't record suspicious; still not fake
    get project_packet_path(@project)

    assert_select "#packet_certificate_count", text: certificates_before.to_s
    assert_select "#packet_excluded", count: 0
    assert_select "#packet_empty", count: 0
  end

  test "when every certificate is confirmed fake, the page says so rather than that no one holds one" do
    sign_in_as users(:viewer)
    get project_packet_path(@project)
    assert_operator css_select("#packet_certificate_count").text.to_i, :>, 0
    assert_select "#packet_empty", count: 0

    Certificate.current.update_all(authenticity_status: Certificate.authenticity_statuses[:not_found],
      authenticity_method: Authenticity::PERSON_METHOD)
    get project_packet_path(@project)

    assert_select "#packet_certificate_count", text: "0"
    assert_select "#packet_empty", text: /Nothing to package: every current certificate is confirmed fake and left out; index\.pdf lists them\./
    assert_select "#packet_empty", text: /no one on this project holds/, count: 0
  end

  test "viewer can build a packet; the page polls while building" do
    sign_in_as users(:viewer)

    assert_enqueued_with(job: Compliance::PacketJob, args: [ @project, { built_by_id: users(:viewer).id } ]) do
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

  test "a ready packet says how long the zip is kept" do
    travel_to Time.zone.local(2026, 11, 4, 15, 30) do
      Compliance::PacketBuilder.new(@project).attach!
      sign_in_as users(:viewer)

      get project_packet_path(@project)

      assert_select "#packet_status[data-state=ready]"
      assert_select "#packet_kept_until", text: /Nov 11, 2026, then deleted/
    end
  end

  test "once the zip has expired the page says so and offers Rebuild" do
    travel_to 10.days.ago do
      Compliance::PacketBuilder.new(@project).attach!
    end
    Maintenance::PurgeOldPacketsJob.perform_now
    sign_in_as users(:viewer)

    get project_packet_path(@project)

    assert_response :success
    assert_select "#packet_status[data-state=expired]"
    assert_select "#packet_status", text: /The last zip has expired/
    assert_select "#packet_status", text: /was deleted after 7 days/
    assert_select "a", text: "Download zip", count: 0
    assert_select "button", text: "Rebuild packet"

    assert_enqueued_with(job: Compliance::PacketJob) { post project_packet_path(@project) }
  end

  test "lists past builds newest first with who built each and a download of its index PDF" do
    freeze_time
    travel_to 9.days.ago do
      Compliance::PacketBuilder.new(@project).attach!(built_by: users(:manager))
    end
    Maintenance::PurgeOldPacketsJob.perform_now
    certificates(:juan_osha30).files.attach(io: StringIO.new("%PDF-1.4\n"), filename: "osha.pdf", content_type: "application/pdf")
    Compliance::PacketBuilder.new(@project).attach!
    older, newer = @project.packet_builds.order(:built_at).to_a
    sign_in_as users(:viewer)

    get project_packet_path(@project)

    assert_select "#packet_builds tbody tr", count: 2
    assert_select "#packet_builds tbody tr:first-child[id=?]", "packet_build_#{newer.id}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(older)}" do
      assert_select "time[datetime=?]", older.built_at.iso8601
      assert_select "td", text: "Manny Manager"
      assert_select "a[href=?]", rails_blob_path(older.index_pdf, disposition: "attachment"), text: "Index PDF"
    end
    assert_select "##{ActionView::RecordIdentifier.dom_id(newer)}" do
      assert_select "td", text: "—"
      assert_select "td", text: "1" # one file
    end

    get rails_blob_path(older.index_pdf, disposition: "attachment")
    assert_response :redirect
  end

  test "building through the page records who asked" do
    sign_in_as users(:viewer)

    perform_enqueued_jobs(only: Compliance::PacketJob) { post project_packet_path(@project) }

    assert_equal users(:viewer), @project.packet_builds.sole.built_by
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
