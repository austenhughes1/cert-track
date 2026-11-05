require "test_helper"

class Compliance::PacketBuilderTest < ActiveSupport::TestCase
  setup do
    @project = projects(:tower_2417)
    @today = Date.current
  end

  test "includes every file of current required certificates, named Last_First - CODE - exp date" do
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")
    attach certificates(:juan_flagger), "flagger.JPG", jpeg_bytes
    attach certificates(:li_flagger), "front.pdf", pdf_bytes("li front")
    attach certificates(:li_flagger), "back.pdf", pdf_bytes("li back")
    attach certificates(:maria_first_aid), "first aid.png", png_bytes # expired, but still the current certificate

    flagger_expiry = certificates(:juan_flagger).expires_on.iso8601
    li_expiry = certificates(:li_flagger).expires_on.iso8601
    maria_expiry = certificates(:maria_first_aid).expires_on.iso8601

    expected = [
      "Chen_Li - FLAGGER - exp #{li_expiry}.pdf",
      "Chen_Li - FLAGGER - exp #{li_expiry} (2).pdf",
      "Garcia_Maria - FIRSTAID - exp #{maria_expiry}.png",
      "Ortiz_Juan - OSHA30 - exp none.pdf",
      "Ortiz_Juan - FLAGGER - exp #{flagger_expiry}.jpg"
    ]

    assert_equal expected, builder.entries.map(&:name)
  end

  test "leaves out superseded certificates, types a person doesn't need, other types and inactive crew" do
    attach certificates(:juan_flagger_old), "old.pdf", pdf_bytes("superseded")
    # Climber is required of climbers only; Maria is a foreman.
    attach Certificate.create!(crew_member: crew_members(:maria_garcia), certificate_type: certificate_types(:climber),
      completed_on: @today - 10), "climber.pdf", pdf_bytes("not required")
    # HAZWOPER isn't required on the project at all.
    attach Certificate.create!(crew_member: crew_members(:juan_ortiz), certificate_type: certificate_types(:retired_hazwoper),
      completed_on: @today - 10), "hazwoper.pdf", pdf_bytes("other type")
    # Sam is inactive, so not part of the crew even when assigned.
    @project.project_assignments.create!(crew_member: crew_members(:sam_inactive))
    attach certificates(:sam_osha30), "sam.pdf", pdf_bytes("inactive")

    assert_empty builder.entries
    assert_not_includes builder.certificate_cells.map { |_, cell| cell.certificate }, certificates(:juan_flagger_old)
  end

  test "a certificate a person confirmed fake is left out of the zip and listed in the index as left out" do
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")
    attach certificates(:li_flagger), "front.pdf", pdf_bytes("li front")
    certificates(:li_flagger).record_authenticity!(status: :not_found, method: "person", by: users(:manager))

    assert_equal [ "Ortiz_Juan - OSHA30 - exp none.pdf" ], builder.entries.map(&:name)
    assert_not_includes builder.certificate_cells.map { |_, cell| cell.certificate }, certificates(:li_flagger)
    assert_equal [ certificates(:li_flagger) ], builder.excluded_cells.map { |_, cell| cell.certificate }
    assert_equal [ [ "Chen, Li", "FLAGGER - Flagger", certificates(:li_flagger).expires_on, "Failed verification with the issuer" ] ],
      builder.send(:index_excluded).map { |excluded| [ excluded.person, excluded.type, excluded.expires_on, excluded.reason ] }
    assert_equal 5, builder.send(:index_gaps).size, "listed once, as left out, not again as a gap"
    assert_not_includes builder.send(:index_rows).map(&:number), "FL-55501"

    Dir.mktmpdir do |dir|
      path = builder.write_zip(File.join(dir, "packet.zip"))

      Zip::File.open(path) do |zip|
        assert_equal [ "index.pdf", "Ortiz_Juan - OSHA30 - exp none.pdf" ], zip.entries.map(&:name)
        text = pdf_strings(zip.read("index.pdf"))
        assert_includes text, "Left out of this packet (1)"
        assert_includes text, "Failed verification with the issuer"
        assert_includes text, "Chen, Li"
        assert_not_includes text, "FL-55501"
        assert_includes text, "Missing and expired (5)"
        assert(text.any? { |line| line.include?("Failed verification with the issuer: 1") })
        assert_no_match(/fake|flagged|review/i, text.join(" "), "the client's index never says fake or flagged")
      end
    end
  end

  test "the index never claims everyone holds a current certificate when the only gap is a left-out one" do
    project = Project.create!(name: "Gate One", code: "G1")
    project.project_requirements.create!(certificate_type: certificate_types(:osha30))
    project.project_assignments.create!(crew_member: crew_members(:juan_ortiz))
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")
    certificates(:juan_osha30).record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    builder = Compliance::PacketBuilder.new(project, today: @today)

    assert_empty builder.entries
    assert_equal [ certificates(:juan_osha30) ], builder.excluded_cells.map { |_, cell| cell.certificate }

    text = pdf_strings(builder.index_pdf).join(" ")
    assert_includes text, "Left out of this packet (1)"
    assert_includes text, "Missing and expired (0)"
    assert_not_includes text, "Everyone holds a current certificate"
    assert_not_includes text, "No current certificates on file"
    assert_no_match(/fake|flagged|review/i, text)
  end

  test "a genuine certificate stays current and in the zip when a newer one is confirmed fake" do
    genuine = attach(certificates(:dave_flagger), "dave.pdf", pdf_bytes("dave genuine"))
    fake = attach(Certificate.create!(crew_member: crew_members(:dave_miller), certificate_type: certificate_types(:flagger),
      certificate_number: "FL-FAKE", completed_on: @today - 10), "fake.pdf", pdf_bytes("dave fake"))
    assert_equal fake, builder.report.row_for(crew_members(:dave_miller).id).cell_for(certificate_types(:flagger).id).certificate

    fake.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    genuine.reload.record_authenticity!(status: :not_found, method: "automatic:national_cpr_foundation")
    builder = Compliance::PacketBuilder.new(@project, today: @today)

    cell = builder.report.row_for(crew_members(:dave_miller).id).cell_for(certificate_types(:flagger).id)
    assert_equal [ genuine, "valid" ], [ cell.certificate, cell.status ], "a later automatic not found only flags it for review"
    assert_empty builder.excluded_cells
    Dir.mktmpdir do |dir|
      Zip::File.open(builder.write_zip(File.join(dir, "packet.zip"))) do |zip|
        assert_equal pdf_bytes("dave genuine"), zip.read("Miller_David - FLAGGER - exp #{genuine.expires_on.iso8601}.pdf")
        assert_not_includes zip.entries.map(&:name).join(" "), "exp #{fake.expires_on.iso8601}"
        assert_not_includes pdf_strings(zip.read("index.pdf")), "FL-FAKE"
      end
    end
  end

  test "a certificate only flagged for review goes in the zip like any other, and the index doesn't say so" do
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")
    attach certificates(:li_flagger), "front.pdf", pdf_bytes("li front")
    attach certificates(:juan_flagger), "flagger.pdf", pdf_bytes("juan flagger")
    attach certificates(:dave_flagger), "dave.pdf", pdf_bytes("dave flagger")
    certificates(:li_flagger).record_authenticity!(status: :not_found, method: "automatic:national_cpr_foundation")
    certificates(:juan_osha30).record_authenticity!(status: :mismatch, method: "qr_details:qr_details_360training")
    certificates(:juan_flagger).record_authenticity!(status: :suspicious, method: "qr_link")
    certificates(:dave_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:suspicious], authenticity_method: "person")
    li_expiry = certificates(:li_flagger).expires_on.iso8601

    assert_empty builder.excluded_cells
    assert_equal [ "Chen_Li - FLAGGER - exp #{li_expiry}.pdf", "Miller_David - FLAGGER - exp #{certificates(:dave_flagger).expires_on.iso8601}.pdf",
      "Ortiz_Juan - OSHA30 - exp none.pdf", "Ortiz_Juan - FLAGGER - exp #{certificates(:juan_flagger).expires_on.iso8601}.pdf" ],
      builder.entries.map(&:name)
    assert_includes builder.send(:index_rows).map { |row| [ row.number, row.status ] }, [ "FL-55501", "valid" ]

    Dir.mktmpdir do |dir|
      Zip::File.open(builder.write_zip(File.join(dir, "packet.zip"))) do |zip|
        assert_equal pdf_bytes("li front"), zip.read("Chen_Li - FLAGGER - exp #{li_expiry}.pdf")
        text = pdf_strings(zip.read("index.pdf"))
        assert_includes text, "FL-55501"
        assert_not(text.any? { |line| line.start_with?("Left out of this packet") })
        assert_no_match(/fake|flagged|review|failed verification|not found|doesn.t match|suspicious/i, text.join(" "))
      end
    end
  end

  test "the build record counts a left-out certificate as a gap, not as a certificate in the zip" do
    attach certificates(:li_flagger), "front.pdf", pdf_bytes("li front")
    certificates(:li_flagger).record_authenticity!(status: :mismatch, method: "person", by: users(:manager))
    certificates_in_zip = builder.certificate_cells.size

    builder.attach!

    build = @project.packet_builds.sole
    assert_equal [ certificates_in_zip, 0, 6 ], [ build.certificate_count, build.file_count, build.gap_count ]
    assert_equal 11, build.certificate_count
  end

  test "the build record counts a certificate flagged for review as one in the zip, not as a gap" do
    attach certificates(:li_flagger), "front.pdf", pdf_bytes("li front")
    certificates(:li_flagger).record_authenticity!(status: :suspicious, method: "qr_link")

    builder.attach!

    build = @project.packet_builds.sole
    assert_equal [ 12, 1, 5 ], [ build.certificate_count, build.file_count, build.gap_count ]
  end

  test "write_zip puts index.pdf first and copies each file byte for byte" do
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")
    attach certificates(:dave_cdl_a), "cdl.jpg", jpeg_bytes

    Dir.mktmpdir do |dir|
      path = builder.write_zip(File.join(dir, "packet.zip"))

      Zip::File.open(path) do |zip|
        assert_equal [ "index.pdf", "Miller_David - CDLA - exp #{certificates(:dave_cdl_a).expires_on.iso8601}.jpg",
          "Ortiz_Juan - OSHA30 - exp none.pdf" ], zip.entries.map(&:name)
        assert_equal pdf_bytes("juan osha"), zip.read("Ortiz_Juan - OSHA30 - exp none.pdf")

        index = zip.read("index.pdf")
        assert_operator CombinePDF.parse(index).pages.size, :>=, 1
        text = pdf_strings(index)
        assert_includes text, "Ortiz_Juan - OSHA30 - exp none.pdf"
        assert_includes text, "CO-123456789"
        assert_includes text, "Missing and expired (5)"
        assert_includes text, "Garcia, Maria"
      end
    end
  end

  test "index rows list each certificate with its files and the gaps" do
    attach certificates(:li_flagger), "front.pdf", pdf_bytes("li front")

    rows = builder.send(:index_rows)
    li_row = rows.find { |row| row.person == "Chen, Li" && row.type.start_with?("FLAGGER") }
    assert_equal "FL-55501", li_row.number
    assert_equal [ "Chen_Li - FLAGGER - exp #{certificates(:li_flagger).expires_on.iso8601}.pdf" ], li_row.file_names
    assert_equal [], rows.find { |row| row.person == "Ortiz, Juan" && row.type.start_with?("OSHA30") }.file_names

    gaps = builder.send(:index_gaps).map { |gap| [ gap.person, gap.type.split(" - ").first, gap.status ] }
    assert_equal [
      [ "Chen, Li", "FIRSTAID", "expired" ], [ "Chen, Li", "CLIMBER", "missing" ], [ "Garcia, Maria", "FLAGGER", "missing" ],
      [ "Garcia, Maria", "FIRSTAID", "expired" ], [ "Miller, David", "FIRSTAID", "missing" ]
    ].sort, gaps.sort
  end

  test "attach! stores the zip as project.packet and stamps packet_built_at" do
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")

    freeze_time do
      builder.attach!

      @project.reload
      assert @project.packet.attached?
      assert_equal "2417-packet-#{@today.iso8601}.zip", @project.packet.filename.to_s
      assert_equal "application/zip", @project.packet.content_type
      assert_equal Time.current, @project.packet_built_at
    end

    @project.packet.blob.open do |file|
      Zip::File.open(file.path) { |zip| assert_equal [ "index.pdf", "Ortiz_Juan - OSHA30 - exp none.pdf" ], zip.entries.map(&:name) }
    end
  end

  test "rebuilding replaces the previous packet" do
    builder.attach!
    first_blob = @project.reload.packet.blob

    Compliance::PacketBuilder.new(@project).attach!

    assert_not_equal first_blob, @project.reload.packet.blob
    assert_equal 1, ActiveStorage::Attachment.where(record: @project, name: "packet").count
  end

  test "attach! records the build: who, when, counts, and a copy of the zip's index.pdf" do
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")
    attach certificates(:li_flagger), "front.pdf", pdf_bytes("li front")
    attach certificates(:li_flagger), "back.pdf", pdf_bytes("li back")

    freeze_time do
      assert_difference -> { @project.packet_builds.count }, 1 do
        builder.attach!(built_by: users(:viewer))
      end

      build = @project.packet_builds.sole
      assert_equal users(:viewer), build.built_by
      assert_equal Time.current, build.built_at
      assert_equal @project.reload.packet_built_at, build.built_at
      assert_equal "2417-packet-#{@today.iso8601}.zip", build.packet_filename
      assert_equal [ builder.certificate_cells.size, 3, builder.report.gaps.size ], [ build.certificate_count, build.file_count, build.gap_count ]
      assert_equal "2417-packet-#{@today.iso8601}-index.pdf", build.index_pdf.filename.to_s
      assert_equal "application/pdf", build.index_pdf.content_type

      index = build.index_pdf.download
      @project.packet.blob.open { |file| Zip::File.open(file.path) { |zip| assert_equal zip.read("index.pdf"), index } }
      assert_includes pdf_strings(index), "Generated #{Time.current.strftime("%b %-d, %Y %-l:%M %p %Z")} (America/Denver)"
    end
  end

  test "rebuilding keeps each earlier build's record and index PDF" do
    travel_to 2.days.ago do
      Compliance::PacketBuilder.new(@project).attach!(built_by: users(:manager))
    end
    first = @project.packet_builds.sole
    first_index = first.index_pdf.download
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")

    Compliance::PacketBuilder.new(@project).attach!

    builds = @project.packet_builds.newest_first.to_a
    assert_equal 2, builds.size
    assert_equal first, builds.last
    assert_nil builds.first.built_by
    assert_equal [ 0, 1 ], builds.map(&:file_count).reverse
    assert_equal first_index, first.reload.index_pdf.download
    assert_not_equal first.index_pdf.blob, builds.first.index_pdf.blob
  end

  test "a failed build records nothing and leaves the earlier packet in place" do
    builder.attach!
    packet_blob = @project.reload.packet.blob
    attach certificates(:juan_osha30), "osha.pdf", pdf_bytes("juan osha")
    file = certificates(:juan_osha30).files.first.blob
    file.service.delete(file.key) # file gone from storage

    assert_raises(ActiveStorage::FileNotFoundError) { Compliance::PacketBuilder.new(@project).attach! }

    assert_equal 1, @project.packet_builds.count
    assert_equal packet_blob, @project.reload.packet.blob
  end

  test "a project with no certificate files still gets an index" do
    Dir.mktmpdir do |dir|
      path = builder.write_zip(File.join(dir, "packet.zip"))
      Zip::File.open(path) { |zip| assert_equal [ "index.pdf" ], zip.entries.map(&:name) }
    end
  end

  test "sanitizes odd names and falls back to the content type for the extension" do
    member = CrewMember.create!(first_name: "José", last_name: "Núñez/../Ortiz", crew_role: crew_roles(:operator))
    @project.project_assignments.create!(crew_member: member)
    certificate = Certificate.create!(crew_member: member, certificate_type: certificate_types(:osha30), completed_on: @today - 30)
    attach certificate, "scan", pdf_bytes("no extension")

    assert_equal [ "Nunez .. Ortiz_Jose - OSHA30 - exp none.pdf" ], builder.entries.map(&:name)
  end

  test "sanitize strips path separators and control characters and collapses odd characters" do
    sanitize = ->(text) { Compliance::PacketBuilder.sanitize(text) }

    assert_equal "etc passwd", sanitize.call("../../etc/passwd")
    assert_equal "C_ Windows", sanitize.call("C:\\Windows")
    assert_equal "Garcia-Lopez", sanitize.call("García-López")
    assert_equal "O'Brien", sanitize.call("O'Brien")
    assert_equal "BadName", sanitize.call("Bad\u0000Name\r\n")
    assert_equal "a_b_c_d", sanitize.call("a:b*?c|d")
    assert_equal "unnamed", sanitize.call(" .. ")
    assert_equal 60, sanitize.call("x" * 100).length
  end

  test "slug_for uses a file-safe project code, or the id" do
    assert_equal "2417", Compliance::PacketBuilder.slug_for(@project)
    assert_equal "24-17-A", Compliance::PacketBuilder.slug_for(Project.new(code: "24/17 a"))
    project = Project.create!(name: "No code")
    assert_equal project.id.to_s, Compliance::PacketBuilder.slug_for(project)
  end

  private
    def builder
      @builder ||= Compliance::PacketBuilder.new(@project, today: @today)
    end

    def attach(certificate, filename, bytes)
      content_type = Marcel::MimeType.for(StringIO.new(bytes), name: filename)
      certificate.files.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
      certificate
    end

    def pdf_bytes(label)
      "%PDF-1.4\n% #{label}\n%%EOF\n"
    end

    def jpeg_bytes
      "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00".b
    end

    def png_bytes
      "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b
    end

    def pdf_strings(data)
      data.scan(/<([0-9a-fA-F]+)> Tj/).map { |(hex)| [ hex ].pack("H*") }
    end
end
