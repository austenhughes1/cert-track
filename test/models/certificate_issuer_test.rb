require "test_helper"

class CertificateIssuerTest < ActiveSupport::TestCase
  def build(**attrs)
    CertificateIssuer.new({ name: "Summit Safety Training", code: "SUMMIT" }.merge(attrs))
  end

  test "requires name and code, unique case-insensitively" do
    issuer = CertificateIssuer.new
    assert_not issuer.valid?
    assert_includes issuer.errors[:name], "can't be blank"
    assert_includes issuer.errors[:code], "can't be blank"

    build.save!
    assert_not build(code: "OTHER", name: "summit safety training").valid?
    assert_not build(name: "Other", code: "summit").valid?
  end

  test "normalizes name, code, aliases, domains and blank texts" do
    issuer = CertificateIssuer.create!(name: "  Summit   Safety ", code: " summit-1 ", aliases: [ " Summit ", "summit", "", " SST " ],
      domains: [ "https://verify.summitsafety.org/x", "www.SummitSafety.org", "not a domain", "training.co.uk" ],
      lookup_url: "  ", link_template: " ", automatic_check: "", verification_notes: "  Enter the ID. ")

    assert_equal [ "Summit Safety", "SUMMIT-1" ], [ issuer.name, issuer.code ]
    assert_equal [ "Summit", "SST" ], issuer.aliases
    assert_equal [ "summitsafety.org", "training.co.uk" ], issuer.domains
    assert_equal [ nil, nil, nil, "Enter the ID." ], [ issuer.lookup_url, issuer.link_template, issuer.automatic_check, issuer.verification_notes ]
  end

  test "code format, https lookup page, a link template with {code}, a known automatic check" do
    assert_not build(code: "SUMMIT SAFETY").valid?
    assert_not build(lookup_url: "http://summitsafety.org/verify").valid?
    assert build(lookup_url: "https://summitsafety.org/verify").valid?
    assert_not build(link_template: "https://summitsafety.org/verify").valid?, "no {code}"
    assert_not build(link_template: "javascript:alert('{code}')").valid?
    assert build(link_template: "https://summitsafety.org/verify/{code}").valid?

    issuer = build(automatic_check: "scrape_everything")
    assert_not issuer.valid?
    assert_match "is not a known checker", issuer.errors[:automatic_check].sole
    assert build(automatic_check: "aha_ecards").automatic_check?
    assert_not build.automatic_check?
  end

  test "find_by_code ignores case and whitespace" do
    issuer = build.tap(&:save!)

    assert_equal issuer, CertificateIssuer.find_by_code(" summit ")
    assert_nil CertificateIssuer.find_by_code("NOPE")
    assert_nil CertificateIssuer.find_by_code(nil)
  end

  test "host_of: lowercased, without www. or a trailing dot; nil for anything without a dotted host" do
    {
      "https://www.RedCross.org./take-a-class?x=1" => "redcross.org",
      "WWW.REDCROSS.ORG" => "redcross.org",
      "verify.360training.com/q" => "verify.360training.com",
      "http://1.2.3.4/x" => "1.2.3.4"
    }.each do |text, host|
      assert_equal host, CertificateIssuer.host_of(text), text
    end
    [ nil, "", "  ", "TEST123", "https://localhost/x", "https://exa mple.com", "https://redсross.org/", "mailto:a@b" ].each do |text|
      assert_nil CertificateIssuer.host_of(text), text.inspect
    end
  end

  test "registrable_domain keeps the last two labels, or three under a country's generic second level" do
    {
      "https://verify.360training.com/q" => "360training.com",
      "www.redcross.org" => "redcross.org",
      "certs.training.co.uk" => "training.co.uk",
      "uni.ac.nz" => "uni.ac.nz",
      "a.b.example.de" => "example.de",
      "redcross.org." => "redcross.org"
    }.each do |text, domain|
      assert_equal domain, CertificateIssuer.registrable_domain(text), text
    end
    assert_nil CertificateIssuer.registrable_domain("not a web address")
    assert_equal "redсross.org", CertificateIssuer.domain_of_host("www.redсross.org"), "any letters, for Lookalike"
    assert_nil CertificateIssuer.domain_of_host("")
  end

  test "for_url finds the active issuer on the URL's domain" do
    summit = build(domains: [ "summitsafety.org" ]).tap(&:save!)

    assert_equal summit, CertificateIssuer.for_url("https://verify.summitsafety.org/c/1")
    assert_nil CertificateIssuer.for_url("https://summitsafety-verify.com/c/1")
    assert_nil CertificateIssuer.for_url(nil)

    summit.update!(active: false)
    assert_nil CertificateIssuer.for_url("https://verify.summitsafety.org/c/1")
  end

  test "owns_url? and link_for, with the code URL-encoded" do
    issuer = build(domains: [ "summitsafety.org" ], link_template: "https://verify.summitsafety.org/c/{code}?ref=qr")

    assert issuer.owns_url?("https://www.summitsafety.org/x")
    assert_not issuer.owns_url?("https://summitsafety.org.evil.com/x")
    assert_not issuer.owns_url?(nil)
    assert_equal "https://verify.summitsafety.org/c/SUM%201%2F2%26x%3D%3Cb%3E?ref=qr", issuer.link_for(" SUM 1/2&x=<b> ")
    assert_nil issuer.link_for("")
    assert_nil build.link_for("SUM-1"), "no template"
  end

  test "fuzzy_match scores names and aliases" do
    summit = build(aliases: [ "SST Safety Training" ]).tap(&:save!)

    issuer, similarity = CertificateIssuer.fuzzy_match("Summit Safety Training Co").first
    assert_equal summit, issuer
    assert_operator similarity, :>=, CertificateIssuer::FUZZY_THRESHOLD
    assert_equal summit, CertificateIssuer.fuzzy_match("SST Safety Training").first.first
    assert_empty CertificateIssuer.fuzzy_match("Zzyzx")
    assert_empty CertificateIssuer.fuzzy_match(" ")
  end

  # --- "Other..." ---

  test "find_or_create_from_name! adds an issuer with a code made from the name" do
    issuer = CertificateIssuer.find_or_create_from_name!("  Granite  Peak Safety ")

    assert issuer.previously_new_record?
    assert_equal [ "Granite Peak Safety", "GRANITEPEAKSAFETY" ], [ issuer.name, issuer.code ]
    assert issuer.verified_by_unknown?
    assert_empty issuer.domains
    assert_equal "ABCDEFGHIJKLMNOPQRST", CertificateIssuer.find_or_create_from_name!("Abcdefghij klmnopqrst uvwxyz").code, "20 letters at most"
  end

  test "find_or_create_from_name! picks a free code: -2, -3, ...; ISSUER for a name with no letters or digits" do
    CertificateIssuer.create!(name: "Granite Peak", code: "GRANITEPEAKSAFETY")
    CertificateIssuer.create!(name: "Granite Peak 2", code: "GRANITEPEAKSAFETY-2")

    assert_equal "GRANITEPEAKSAFETY-3", CertificateIssuer.find_or_create_from_name!("Granite-Peak Safety").code
    assert_equal "ISSUER", CertificateIssuer.find_or_create_from_name!("— ★ —").code
    assert_equal "ISSUER-2", CertificateIssuer.find_or_create_from_name!("· · ·").code
  end

  test "find_or_create_from_name! raises on a blank name" do
    error = assert_raises(ActiveRecord::RecordInvalid) { CertificateIssuer.find_or_create_from_name!("  ") }
    assert_includes error.record.errors[:name], "can't be blank"
  end

  test "find_or_create_from_name! reuses an issuer of that name or alias, an active one first" do
    CertificateIssuer.seed_defaults!
    red_cross = CertificateIssuer.find_by_code("REDCROSS")
    training = CertificateIssuer.find_by_code("360TRAINING")

    assert_no_difference -> { CertificateIssuer.count } do
      assert_equal red_cross, CertificateIssuer.find_or_create_from_name!("american red cross")
      assert_equal red_cross, CertificateIssuer.find_or_create_from_name!("Red Cross")
      assert_equal training, CertificateIssuer.find_or_create_from_name!("360 Training")
      assert_equal training, CertificateIssuer.find_or_create_from_name!("osha campus")
    end
    assert_not red_cross.reload.previously_new_record?

    retired = CertificateIssuer.create!(name: "Old Red Cross Office", code: "OLDRC", aliases: [ "Red Cross" ], active: false)
    assert_equal red_cross, CertificateIssuer.find_or_create_from_name!("Red Cross"), "the active one wins"
    assert_equal retired, CertificateIssuer.find_or_create_from_name!("old red cross office"), "an inactive one of that name is reused"
  end

  test "find_or_create_from_name! inside a transaction survives another request adding the same name first" do
    existing = CertificateIssuer.create!(name: "Granite Peak Safety", code: "GPS")
    lookups = 0
    real_named = CertificateIssuer.method(:named)
    # The other request's row isn't visible to the first lookup or the uniqueness validation, so
    # the insert hits the unique index (PostgreSQL then aborts the transaction, unless it was a savepoint).
    late_lookup = ->(name) { (lookups += 1) == 1 ? nil : real_named.call(name) }
    unvalidated_insert = ->(**attributes) { CertificateIssuer.new(**attributes).tap { it.save!(validate: false) } }

    CertificateIssuer.transaction do
      replacing(:named, late_lookup) do
        replacing(:create!, unvalidated_insert) do
          assert_equal existing, CertificateIssuer.find_or_create_from_name!("Granite Peak Safety")
        end
      end
      assert CertificateIssuer.exists?(existing.id), "the transaction is still usable after the failed insert"
    end
    assert_equal 2, lookups
  end

  test "find_or_create_from_name! finds the name another request saved first, when validation sees it" do
    existing = CertificateIssuer.create!(name: "Granite Peak Safety", code: "GPS")
    lookups = 0
    real_named = CertificateIssuer.method(:named)

    replacing(:named, ->(name) { (lookups += 1) == 1 ? nil : real_named.call(name) }) do
      assert_equal existing, CertificateIssuer.find_or_create_from_name!("Granite Peak Safety")
    end
  end

  test "find_or_create_from_name! gives up after a few attempts" do
    CertificateIssuer.create!(name: "Granite Peak Safety", code: "GPS")
    lookups = 0

    replacing(:named, ->(_name) { (lookups += 1) && nil }) do
      assert_raises(ActiveRecord::RecordInvalid) { CertificateIssuer.find_or_create_from_name!("Granite Peak Safety") }
    end
    assert_equal CertificateIssuer::CREATE_ATTEMPTS, lookups
  end

  # --- defaults ---

  test "seed_defaults! adds the 18 defaults in order and leaves an admin's edits alone" do
    assert_difference -> { CertificateIssuer.count }, 18 do
      CertificateIssuer.seed_defaults!
    end
    assert_equal [ "REDCROSS", 1 ], CertificateIssuer.find_by_code("REDCROSS").then { [ it.code, it.position ] }

    red_cross = CertificateIssuer.find_by_code("REDCROSS")
    red_cross.update!(lookup_url: "https://www.redcross.org/our-own-page", active: false)

    assert_no_difference -> { CertificateIssuer.count } do
      CertificateIssuer.seed_defaults!
    end
    red_cross.reload
    assert_equal [ "https://www.redcross.org/our-own-page", false ], [ red_cross.lookup_url, red_cross.active ]
  end

  test "an issuer certificates point at can't be destroyed" do
    issuer = build.tap(&:save!)
    certificates(:juan_osha30).update!(certificate_issuer: issuer)

    assert_not issuer.destroy
    assert issuer.errors[:base].any?
  end

  private
    # Replaces the class method CertificateIssuer.<method> with body inside the block.
    def replacing(method, body)
      patch = Module.new { define_method(method, body) }
      CertificateIssuer.singleton_class.prepend(patch)
      yield
    ensure
      patch.send(:remove_method, method)
    end
end
