require "securerandom"
require_relative "import_samples"

# The Phase 3 acceptance zip (docs/PLAN.md, "Phase 3: Bulk import", "Done when"): one upload
# of about 20 SYNTHETIC samples covering every intake path, plus the outcome the pipeline
# should reach for each. Every name, number and issuer is made up; the people and types
# that should match are the crew_members and certificate_types fixtures.
#
#   zip = ImportAcceptanceZip.build                 # dates relative to Date.current
#   zip.bytes                                       # => the upload's bytes
#   zip.candidates                                  # => every file that should become an intake item
#   zip.certificates                                # => [ImportAcceptanceZip::Certificate, ...]
#
# What's inside crew_certs.zip:
#   certs/                    6 single-certificate text PDFs, a course outline (no certificate),
#                             a .DS_Store (junk)
#   scans/                    an image-only PDF that needs OCR
#   packets/crew_packet.pdf   certificate, course outline, certificate, certificate
#   photos/                   JPEG (EXIF-rotated), PNG, WEBP and HEIC photos
#   nested/level1.zip         > level2.zip > 2 more certificates (two levels below the upload)
#   duplicates/               the same bytes as certs/ortiz_osha30.pdf
#   __MACOSX/...              AppleDouble junk
#   notes.txt                 unsupported type
#   ../../evil-<hex>.pdf      zip-slip
module ImportAcceptanceZip
  UPLOAD = "crew_certs.zip".freeze
  HEIC_FIXTURE = File.expand_path("../fixtures/files/imports/synthetic_certificate.heic", __dir__)

  # One certificate the pipeline should find, and what it should make of it.
  #   file          original_filename of the item ("crew_certs.zip/certs/ortiz_osha30.pdf")
  #   page_range    "1", "3"... for PDFs; nil for photos
  #   holder        the holder name as printed (and as OCR must read it)
  #   crew_member   fixture name of the member it should match or suggest, or nil
  #   person_match  :matched | :suggested | :unmatched
  #   type          fixture name of the certificate type, or nil
  #   type_match    :matched | :suggested | :unmatched
  #   expiry        expires_on_source a certificate made from it gets: :printed | :computed | :none
  #                 (nil when the type is unknown)
  #   auto_accept   true when every auto-accept rule holds (with AUTO_ACCEPT_ENABLED on)
  #   ocr           true when the text came from tesseract (scan or photo)
  #   why           what the sample exercises
  Certificate = Data.define(:file, :page_range, :holder, :crew_member, :person_match, :type, :type_match,
    :expiry, :auto_accept, :ocr, :why)

  # bytes:        the upload
  # entries:      every entry name in the top-level zip, as stored
  # candidates:   original_filename of every file that should become an intake item
  #               (what ExpandJob counts in files_count): nested zips opened, junk left out
  # junk:         entry names that must be skipped silently
  # certificates: Certificate expectations, in item order
  # duplicate:    [duplicate file, original file]
  # rejected:     { original_filename => rejection reason (pattern) }
  # packet:       the multi-certificate PDF's original_filename
  # evil_name:    the zip-slip entry's basename, unique per build
  Build = Data.define(:bytes, :entries, :candidates, :junk, :certificates, :duplicate, :rejected, :packet, :evil_name) do
    def certificate(file, page_range = :any)
      certificates.find { |expected| expected.file == file && (page_range == :any || expected.page_range == page_range) } or
        raise ArgumentError, "no expected certificate for #{file} #{page_range}"
    end

    def auto_accepted
      certificates.select(&:auto_accept)
    end

    def needs_review_with_auto_accept
      certificates.reject(&:auto_accept)
    end
  end

  module_function

  def build(today: Date.current)
    day = ->(offset) { (today + offset).iso8601 }
    years_later = ->(offset, years) { (today + offset).advance(years: years).iso8601 }
    path = ->(name) { "#{UPLOAD}/#{name}" }
    evil_name = "evil-#{SecureRandom.hex(4)}.pdf"
    certificates = []
    expect = ->(file, page_range, holder, crew_member, person_match, type, type_match, expiry, auto_accept, why, ocr: false) do
      certificates << Certificate.new(file: path.call(file), page_range:, holder:, crew_member:, person_match:, type:,
        type_match:, expiry:, auto_accept:, ocr:, why:)
    end

    # --- single-certificate text PDFs ---
    ortiz_osha = ImportSamples.pdf({ name: "OSHA 30-Hour Construction Industry Outreach Training", holder: "Juan A. Ortiz",
      number: "30-7654321", completed: day.(-200), issuer: "Example Safety Training LLC" })
    expect.("certs/ortiz_osha30.pdf", "1", "Juan A. Ortiz", :juan_ortiz, :matched, :osha30, :matched, :none, true,
      "exact name (middle initial dropped), type by alias, type never expires")

    garcia_flagger = ImportSamples.pdf({ name: "Traffic Control Flagger", holder: "Mari Garcia", number: "FL-30303",
      completed: day.(-150), expires: years_later.(-150, 3), issuer: "Example Traffic Safety Inc" })
    expect.("certs/garcia_flagger.pdf", "1", "Mari Garcia", :maria_garcia, :matched, :flagger, :matched, :printed, true,
      "preferred name, type by alias, printed expiry")

    chen_first_aid = ImportSamples.pdf({ name: "Adult First Aid CPR AED", holder: "Li Chenn", number: "FA-1001",
      completed: day.(-90), issuer: "Example First Aid Chapter" })
    expect.("certs/chen_first_aid.pdf", "1", "Li Chenn", :li_chen, :suggested, :first_aid, :matched, :computed, false,
      "variant spelling: suggested, never auto-accepted")

    miller_cdl = ImportSamples.pdf({ name: "CDL Class A", holder: "Dave Miller", number: "CDL-0042", completed: day.(-30),
      expires: years_later.(-30, 5), issuer: "Example Motor Vehicle Division" })
    expect.("certs/miller_cdl.pdf", "1", "Dave Miller", :dave_miller, :matched, :cdl_a, :matched, :printed, true,
      "preferred name, type by exact name")

    unknown = ImportSamples.pdf({ name: "Confined Space Entry", holder: "Robert Example", number: "CS-777",
      completed: day.(-60), issuer: "Example Safety Training LLC" })
    expect.("certs/example_confined_space.pdf", "1", "Robert Example", nil, :unmatched, nil, :unmatched, nil, false,
      "unknown person and unknown type")

    future = ImportSamples.pdf({ name: "Flagger Certification", holder: "Jon Ortiz", number: "FL-90909",
      completed: day.(60), issuer: "Example Traffic Safety Inc" })
    expect.("certs/ortiz_flagger_future.pdf", "1", "Jon Ortiz", :juan_ortiz, :matched, :flagger, :matched, :computed, false,
      "alias exact match, but the completion date is in the future")

    outline = ImportSamples.pdf(:outline)

    # --- scanned (image-only) PDF ---
    scan = ImportSamples.scanned_pdf({ name: "Authorized Climber", holder: "ORTIZ, JUAN", number: "CL-5150",
      completed: day.(-45), issuer: "Example Tower Safety Inc" })
    expect.("scans/ortiz_climber_scan.pdf", "1", "ORTIZ, JUAN", :juan_ortiz, :matched, :climber, :matched, :computed, true,
      "OCR of a scan, Last, First name, computed expiry", ocr: true)

    # --- multi-certificate PDF: certificate, outline, certificate, certificate ---
    packet = ImportSamples.pdf(
      { name: "Flagger", holder: "Li Chen", number: "FL-44001", completed: day.(-100), issuer: "Example Traffic Safety Inc" },
      :outline,
      { name: "Commercial Driver License Class A", holder: "David Millar", number: "CDL-8800", completed: day.(-400),
        expires: years_later.(-400, 5), issuer: "Example Motor Vehicle Division" },
      { name: "First Aid CPR AED for Adults", holder: "Sam Price", number: "FA-2002", completed: day.(-20),
        issuer: "Example First Aid Chapter" }
    )
    expect.("packets/crew_packet.pdf", "1", "Li Chen", :li_chen, :matched, :flagger, :matched, :computed, true,
      "page 1 of a multi-certificate PDF")
    expect.("packets/crew_packet.pdf", "3", "David Millar", :dave_miller, :suggested, :cdl_a, :matched, :printed, false,
      "page 3 (after an outline page): variant spelling")
    expect.("packets/crew_packet.pdf", "4", "Sam Price", :sam_inactive, :suggested, :first_aid, :suggested, :computed, false,
      "page 4: inactive member, type only fuzzy-matched")

    # --- photos ---
    jpeg = ImportSamples.image({ name: "OSHA 30 Hour Construction Safety", holder: "Li Chen", number: "30-2468024",
      completed: day.(-75), issuer: "Example Safety Training LLC" }, format: :jpeg, orientation: 6)
    expect.("photos/chen_osha30.jpg", nil, "Li Chen", :li_chen, :matched, :osha30, :matched, :none, true,
      "JPEG stored rotated (EXIF orientation 6)", ocr: true)

    png = ImportSamples.image({ name: "Flagger Certification", holder: "Davd Miller", number: "FL-12121",
      completed: day.(-10), issuer: "Example Traffic Safety Inc" }, format: :png)
    expect.("photos/miller_flagger.png", nil, "Davd Miller", :dave_miller, :suggested, :flagger, :matched, :computed, false,
      "PNG photo, misspelled name", ocr: true)

    webp = ImportSamples.image({ name: "Tower Climber", holder: "Maria Garcia", number: "CL-3434", completed: day.(-120),
      issuer: "Example Tower Safety Inc" }, format: :webp)
    expect.("photos/garcia_climber.webp", nil, "Maria Garcia", :maria_garcia, :matched, :climber, :matched, :computed, true,
      "WEBP photo, type by alias", ocr: true)

    # A committed synthetic HEIC, so this works where libheif can't encode (CI): "Maria L. Example",
    # "Aerial Lift Operator Training", completed 2025-06-02, expires 2028-06-02.
    heic = File.binread(HEIC_FIXTURE)
    expect.("photos/example_aerial_lift.heic", nil, "Maria L. Example", nil, :unmatched, nil, :unmatched, :printed, false,
      "HEIC photo, unknown person and type", ocr: true)

    # --- a zip in a zip in the upload (two levels below it: the deepest that is read) ---
    chen_cdl = ImportSamples.pdf({ name: "CDL Class A", holder: "Li Chen", number: "CDL-5511", completed: day.(-250),
      expires: years_later.(-250, 5), issuer: "Example Motor Vehicle Division" })
    rosa = ImportSamples.pdf({ name: "Traffic Control Flagger", holder: "Rosa Example", number: "FL-6060", completed: day.(-15),
      issuer: "Example Traffic Safety Inc" })
    level1 = ImportSamples.zip("level2.zip" => ImportSamples.zip("chen_cdl.pdf" => chen_cdl, "example_flagger.pdf" => rosa))
    expect.("nested/level1.zip/level2.zip/chen_cdl.pdf", "1", "Li Chen", :li_chen, :matched, :cdl_a, :matched, :printed, true,
      "two zips deep")
    expect.("nested/level1.zip/level2.zip/example_flagger.pdf", "1", "Rosa Example", nil, :unmatched, :flagger, :matched,
      :computed, false, "two zips deep, unknown person")

    entries = [
      [ "certs/", nil ],
      [ "certs/ortiz_osha30.pdf", ortiz_osha ],
      [ "certs/garcia_flagger.pdf", garcia_flagger ],
      [ "certs/chen_first_aid.pdf", chen_first_aid ],
      [ "certs/miller_cdl.pdf", miller_cdl ],
      [ "certs/example_confined_space.pdf", unknown ],
      [ "certs/ortiz_flagger_future.pdf", future ],
      [ "certs/course_outline.pdf", outline ],
      [ "certs/.DS_Store", "\x00\x00\x00\x01Bud1".b ],
      [ "scans/ortiz_climber_scan.pdf", scan ],
      [ "packets/crew_packet.pdf", packet ],
      [ "photos/chen_osha30.jpg", jpeg ],
      [ "photos/miller_flagger.png", png ],
      [ "photos/garcia_climber.webp", webp ],
      [ "photos/example_aerial_lift.heic", heic ],
      [ "nested/level1.zip", level1 ],
      [ "duplicates/ortiz_osha30 (copy).pdf", ortiz_osha ],
      [ "__MACOSX/certs/._ortiz_osha30.pdf", "\x00\x05\x16\x07AppleDouble junk".b ],
      [ "notes.txt", "Renew Li's first aid card in May.\n" ],
      [ "../../#{evil_name}", ImportSamples.pdf({ holder: "Evil Example", number: "EVIL-1" }) ]
    ]

    junk = [ "certs/.DS_Store", "__MACOSX/certs/._ortiz_osha30.pdf" ]
    candidates = entries.filter_map do |name, _|
      next if name.end_with?("/") || junk.include?(name)

      name == "nested/level1.zip" ? nil : path.call(name)
    end
    candidates += [ "nested/level1.zip/level2.zip/chen_cdl.pdf", "nested/level1.zip/level2.zip/example_flagger.pdf" ].map(&path)

    Build.new(
      bytes: ImportSamples.zip(entries),
      entries: entries.map(&:first),
      candidates: candidates,
      junk: junk,
      certificates: certificates,
      duplicate: [ path.call("duplicates/ortiz_osha30 (copy).pdf"), path.call("certs/ortiz_osha30.pdf") ],
      rejected: { # the course outline is not here: the AI finding no certificate sends it to review
        path.call("notes.txt") => /\AUnsupported file type/,
        path.call("../../#{evil_name}") => /zip-slip/
      },
      packet: path.call("packets/crew_packet.pdf"),
      evil_name: evil_name
    )
  end

  # A small upload for the quota test: two certificates and a course outline.
  def small(today: Date.current)
    ImportSamples.zip(
      "ortiz.pdf" => ImportSamples.pdf({ holder: "Juan A. Ortiz", completed: (today - 200).iso8601 }),
      "garcia.pdf" => ImportSamples.pdf({ name: "Traffic Control Flagger", holder: "Mari Garcia", number: "FL-30303",
        completed: (today - 150).iso8601 }),
      "chen.pdf" => ImportSamples.pdf({ name: "Flagger", holder: "Li Chen", number: "FL-44001", completed: (today - 100).iso8601 })
    )
  end
end
