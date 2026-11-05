require "test_helper"

class Ai::FakeProviderTest < ActiveSupport::TestCase
  MASTER_LIST = [
    [ "OSHA30", "OSHA 30 Construction", [ "OSHA 30-Hour Construction Industry Outreach Training", "OSHA 30 Hour" ] ],
    [ "OSHA10", "OSHA 10 Construction", [ "OSHA 10 Hour" ] ],
    [ "FLAGGER", "Flagger", [ "Flagger Certification" ] ]
  ].freeze
  ISSUER_LIST = [
    [ "REDCROSS", "American Red Cross", [ "Red Cross", "The American National Red Cross" ] ],
    [ "AHA", "American Heart Association", [ "AHA" ] ]
  ].freeze

  CARD = <<~TEXT.freeze
    CERTIFICATE OF COMPLETION
    OSHA 30-Hour Construction Industry Outreach Training
    Awarded to: Juan A. Ortiz
    Certificate No: 30-1234567
    Completed: 2025-03-14
    Issued by: Example Safety Training LLC
  TEXT

  teardown { Ai::FakeProvider.reset! }

  test "reads a synthetic certificate into the model output contract" do
    data = complete([ [ 1, CARD ] ])

    assert_equal({
      "certificates" => [ {
        "holder_name" => "Juan A. Ortiz", "certificate_type_code" => "OSHA30",
        "certificate_name_as_printed" => "OSHA 30-Hour Construction Industry Outreach Training",
        "issuer" => "Example Safety Training LLC", "certificate_issuer_code" => nil, "certificate_number" => "30-1234567",
        "verification_code" => nil, "verification_url" => nil,
        "completed_on" => "2025-03-14", "expires_on" => nil, "confidence" => 0.95,
        "notes" => "No expiration printed", "pages" => [ 1 ]
      } ],
      "non_certificate_pages" => []
    }, data)
  end

  test "one certificate per certificate page; other pages are non-certificate pages" do
    flagger = CARD.sub("OSHA 30-Hour Construction Industry Outreach Training", "Flagger Certification")
      .sub("Juan A. Ortiz", "Li Chen").sub("Issued by", "Expires: 2028-03-14\nIssued by")
    outline = "COURSE OUTLINE\nModule 1: Hazard recognition\nModule 2: Fall protection"

    data = complete([ [ 1, outline ], [ 2, CARD ], [ 3, flagger ] ])

    assert_equal [ [ 2 ], [ 3 ] ], data["certificates"].map { |certificate| certificate["pages"] }
    assert_equal [ "OSHA30", "FLAGGER" ], data["certificates"].map { |certificate| certificate["certificate_type_code"] }
    assert_equal "2028-03-14", data["certificates"].last["expires_on"]
    assert_nil data["certificates"].last["notes"]
    assert_equal [ 1 ], data["non_certificate_pages"]
  end

  test "tolerates OCR case and spacing in the labels" do
    noisy = "  certificate of completion\n\n  Flagger   Certification \nAWARDED  TO :  Li   Chen\n" \
      "certificate no:FL-1\ncompleted :2024-01-02\nISSUED BY:  ATSSA  "

    certificate = complete([ [ 1, noisy ] ])["certificates"].sole

    assert_equal "Li Chen", certificate["holder_name"]
    assert_equal "FLAGGER", certificate["certificate_type_code"]
    assert_equal "FL-1", certificate["certificate_number"]
    assert_equal "2024-01-02", certificate["completed_on"]
    assert_equal "ATSSA", certificate["issuer"]
  end

  test "the longest matching name or alias picks the code, and no match is null" do
    ten = CARD.sub("OSHA 30-Hour Construction Industry Outreach Training", "OSHA 10 Hour Construction Safety")
    unknown = CARD.sub("OSHA 30-Hour Construction Industry Outreach Training", "Bloodborne Pathogens Awareness")

    data = complete([ [ 1, ten ], [ 2, unknown ] ])

    assert_equal [ "OSHA10", nil ], data["certificates"].map { |certificate| certificate["certificate_type_code"] }
  end

  test "confidence drops to 0.6 without a holder, name or completed date" do
    no_holder = CARD.sub("Awarded to: Juan A. Ortiz\n", "")
    bad_date = CARD.sub("2025-03-14", "March 14")

    data = complete([ [ 1, no_holder ], [ 2, bad_date ] ])

    assert_equal [ 0.6, 0.6 ], data["certificates"].map { |certificate| certificate["confidence"] }
    assert_nil data["certificates"].last["completed_on"]
  end

  test "reads the issuer code from the issuer list and the printed verification code and link" do
    card = CARD.sub("Example Safety Training LLC", "The American National Red Cross") +
      "Verification code: RC-123456\nVerify at: redcross.org/confirm\n"
    other = CARD.sub("Example Safety Training LLC", "Ahab Safety Training") # "AHA" inside a word is not the AHA

    data = complete([ [ 1, card ], [ 2, other ] ], issuer_list: ISSUER_LIST)

    first, second = data["certificates"]
    assert_equal [ "REDCROSS", "RC-123456", "redcross.org/confirm" ], first.values_at("certificate_issuer_code", "verification_code", "verification_url")
    assert_equal "OSHA30", first["certificate_type_code"], "the new lines are not the certificate name"
    assert_equal [ nil, nil, nil ], second.values_at("certificate_issuer_code", "verification_code", "verification_url")
  end

  test "reports token usage as text length / 4" do
    prompt = prompt_for([ [ 1, CARD ] ])
    reply = Ai::FakeProvider.new.complete(system: prompt.system, prompt: prompt.user)

    assert_equal ((prompt.system.length + prompt.user.length) / 4.0).ceil, reply.input_tokens
    assert_equal (reply.content.length / 4.0).ceil, reply.output_tokens
  end

  test "records every call" do
    prompt = prompt_for([ [ 1, CARD ] ])
    Ai::FakeProvider.new(model: "fake-vision").complete(system: prompt.system, prompt: prompt.user, images: [ "/tmp/p1.jpg" ])

    call = Ai::FakeProvider.calls.sole
    assert_equal "fake-vision", call.model
    assert_equal [ "/tmp/p1.jpg" ], call.images
    assert_includes call.prompt, "Awarded to: Juan A. Ortiz"
  end

  test "fail_next! raises a quota error for the next calls only" do
    Ai::FakeProvider.fail_next!(times: 2)
    prompt = prompt_for([ [ 1, CARD ] ])
    provider = Ai::FakeProvider.new

    2.times do
      error = assert_raises(Ai::QuotaExceeded) { provider.complete(system: prompt.system, prompt: prompt.user) }
      assert_match "daily free allocation", error.message
    end
    assert provider.complete(system: prompt.system, prompt: prompt.user).content.present?
  end

  test "fail_next! takes any error" do
    Ai::FakeProvider.fail_next!(Ai::ProviderError.new("upstream 502"))

    assert_raises(Ai::ProviderError) { Ai::FakeProvider.new.complete(system: "", prompt: "") }
  end

  test "with_quota_exceeded raises for every call in the block" do
    Ai::FakeProvider.with_quota_exceeded do
      3.times { assert_raises(Ai::QuotaExceeded) { Ai::FakeProvider.new.complete(system: "", prompt: "") } }
    end

    assert Ai::FakeProvider.new.complete(system: "", prompt: "").content
  end

  test "reply_next! returns a canned reply once" do
    Ai::FakeProvider.reply_next!({ "certificates" => [], "non_certificate_pages" => [ 1 ] })
    Ai::FakeProvider.reply_next!("not json")
    provider = Ai::FakeProvider.new

    assert_equal({ "certificates" => [], "non_certificate_pages" => [ 1 ] }, JSON.parse(provider.complete(system: "", prompt: "").content))
    assert_equal "not json", provider.complete(system: "", prompt: "").content
  end

  test "is deterministic" do
    prompt = prompt_for([ [ 1, CARD ], [ 2, "COURSE OUTLINE" ] ])

    first = Ai::FakeProvider.new.complete(system: prompt.system, prompt: prompt.user)
    second = Ai::FakeProvider.new.complete(system: prompt.system, prompt: prompt.user)
    assert_equal first, second
  end

  private
    def prompt_for(pages, issuer_list: [])
      Imports::Extraction::Prompt.new(master_list: MASTER_LIST, pages: pages, page_count: pages.size, issuer_list: issuer_list)
    end

    def complete(pages, issuer_list: [])
      prompt = prompt_for(pages, issuer_list:)
      JSON.parse(Ai::FakeProvider.new.complete(system: prompt.system, prompt: prompt.user).content)
    end
end
