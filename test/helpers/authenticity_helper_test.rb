require "test_helper"

class AuthenticityHelperTest < ActionView::TestCase
  test "authenticity_badge labels and colours every status" do
    Authenticity::LABELS.each do |status, label|
      badge = authenticity_badge(status)
      assert_includes badge, ">#{ERB::Util.html_escape(label)}<", status
      assert_includes badge, %(data-authenticity="#{status}")
    end
    assert_includes authenticity_badge("verified"), "bg-green-100"
    assert_includes authenticity_badge("needs_check"), "bg-amber-100"
    assert_includes authenticity_badge("cannot_verify"), "bg-gray-200"
    Authenticity::FLAGGED_STATUSES.each { assert_includes authenticity_badge(it), "bg-red-600" }
    assert_includes authenticity_badge(Certificate.new(authenticity_status: :mismatch)), "Doesn&#39;t match issuer"
  end

  test "authenticity_badge reads Confirmed fake for a person's not found or doesn't match" do
    [ Certificate.new(authenticity_status: :not_found, authenticity_method: "person"),
      ImportItem.new(authenticity_status: :mismatch, authenticity_method: "person") ].each do |record|
      badge = badge_for(record)
      assert_equal "Confirmed fake", badge.text
      assert_equal "Confirmed fake: #{record.authenticity_label}", badge["title"]
      assert_includes badge["class"], "bg-red-800 text-white ring-1 ring-inset ring-red-900"
      assert_equal [ record.authenticity_status, "true" ], [ badge["data-authenticity"], badge["data-fake"] ]
    end
  end

  test "authenticity_badge keeps the status label for anything only flagged for review" do
    [ Certificate.new(authenticity_status: :not_found, authenticity_method: "automatic:aha_ecards"),
      Certificate.new(authenticity_status: :mismatch, authenticity_method: nil),
      ImportItem.new(authenticity_status: :suspicious, authenticity_method: "rules"),
      Certificate.new(authenticity_status: :suspicious, authenticity_method: "person") ].each do |record| # suspicious is never fake
      badge = badge_for(record)
      assert_equal record.authenticity_label, badge.text
      assert_equal "Flagged for review: #{record.authenticity_label}", badge["title"]
      assert_includes badge["class"], "bg-red-600"
      assert_nil badge["data-fake"]
    end

    assert_nil badge_for(Certificate.new(authenticity_status: :verified, authenticity_method: "person"))["title"]
    assert_nil badge_for("not_found")["title"], "a bare status is just its label"
    assert_nil badge_for("not_found")["data-fake"]
  end

  test "authenticity_result_confirm asks before Not found and Doesn't match only" do
    certificate = Certificate.new
    item = ImportItem.new
    %w[not_found mismatch].each do |status|
      assert_equal "Record this certificate as fake? It will count as not valid and be left out of packets.",
        authenticity_result_confirm(certificate, status)
      assert_equal "Record this as fake? Once accepted, it will count as not valid and be left out of packets.",
        authenticity_result_confirm(item, status)
    end
    %w[verified cannot_verify].each do |status|
      assert_nil authenticity_result_confirm(certificate, status)
      assert_nil authenticity_result_confirm(item, status)
    end
  end

  test "authenticity_fake_sentence says what a confirmed fake means" do
    assert_equal "Confirmed fake: a person checked it with the issuer. It counts as not valid in compliance and is left out of packets.",
      authenticity_fake_sentence(Certificate.new)
    assert_equal "Confirmed fake: a person checked it with the issuer. Once accepted, it counts as not valid in compliance and is " \
      "left out of packets.", authenticity_fake_sentence(ImportItem.new)
  end

  test "authenticity_flagged_sentence says a flag for review still counts, or will once an item is accepted" do
    assert_equal "Flagged for review. It still counts by its dates and goes in packets until someone checks it with the issuer " \
      "and records the result.", authenticity_flagged_sentence(Certificate.new)
    assert_equal "Flagged for review. Once accepted, it counts by its dates and goes in packets until someone checks it with the " \
      "issuer and records the result.", authenticity_flagged_sentence(ImportItem.new)
  end

  test "every person result has a button" do
    assert_equal Authenticity::PERSON_STATUSES.sort, AuthenticityHelper::RESULT_BUTTONS.keys.sort
  end

  test "authenticity_checked_sentence says who checked and when" do
    at = Time.zone.local(2026, 11, 4, 17, 5)
    person = Certificate.new(authenticity_status: :verified, authenticity_method: "person", authenticity_checked_at: at,
      authenticity_checked_by: users(:manager))
    assert_dom_equal %(Checked by Manny Manager on <time datetime="#{at.iso8601}">Nov 4, 2026 at 5:05 PM MST</time>),
      authenticity_checked_sentence(person)

    person.authenticity_checked_by = nil # the user was deleted
    assert_includes authenticity_checked_sentence(person), "Checked by a former user"

    automatic = ImportItem.new(authenticity_method: "automatic:aha_ecards", authenticity_checked_at: at)
    assert_includes authenticity_checked_sentence(automatic), "Checked automatically on"
    assert_equal "Not checked yet", authenticity_checked_sentence(Certificate.new)
  end

  test "authenticity_safe_url only lets https links with a host through" do
    assert_equal "https://www.redcross.org/x?certnumber=1", authenticity_safe_url("https://www.redcross.org/x?certnumber=1")
    assert_equal "https://verify.example.com/", authenticity_safe_url(" https://verify.example.com/ ")
    [ "http://www.redcross.org/", "javascript:alert(1)", "data:text/html,hi", "//redcross.org", "https://", "", nil, "https://exa mple.com" ].each do |url|
      assert_nil authenticity_safe_url(url), url.inspect
    end
  end

  test "authenticity_subject for a certificate and an import item" do
    issuer = CertificateIssuer.new(name: "Summit Safety Training", code: "SUMMIT")
    certificate = certificates(:juan_flagger)
    certificate.assign_attributes(certificate_issuer: issuer, verification_code: "A-1", verification_url: "https://summit.example.com/a")
    subject = authenticity_subject(certificate)
    assert_equal [ issuer, "A-1", "https://summit.example.com/a" ], [ subject.issuer, subject.code, subject.url ]
    assert_equal crew_member_certificate_authenticity_path(certificate.crew_member_id, certificate), subject.update_path
    assert_equal recheck_crew_member_certificate_authenticity_path(certificate.crew_member_id, certificate), subject.recheck_path

    item = import_items(:review_juan_first_aid)
    item.assign_attributes(matched_certificate_issuer: issuer, proposed_verification_code: "B-2")
    subject = authenticity_subject(item)
    assert_equal [ issuer, "B-2", nil ], [ subject.issuer, subject.code, subject.url ]
    assert_equal import_review_authenticity_path(item), subject.update_path
    assert_equal recheck_import_review_authenticity_path(item), subject.recheck_path

    assert_raises(ArgumentError) { authenticity_subject(crew_members(:juan_ortiz)) }
  end

  private
    def badge_for(record_or_status)
      Nokogiri::HTML5.fragment(authenticity_badge(record_or_status)).at_css("span")
    end
end
