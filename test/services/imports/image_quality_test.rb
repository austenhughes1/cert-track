require "test_helper"

class Imports::ImageQualityTest < ActiveSupport::TestCase
  Dates = Data.define(:completed_on)
  READ = { "holder_name" => "Juan Ortiz", "certificate_name_as_printed" => "Flagger", "confidence" => 0.9 }.freeze
  COMPLETED = Dates.new(completed_on: Date.new(2025, 3, 14))

  def item(content_type: "image/jpeg", **attrs)
    ImportItem.new(attrs).tap do |record|
      record.file.attach(io: StringIO.new("x"), filename: "card", content_type: content_type)
    end
  end

  test "a page is unread when a code was seen or the certificate says so, unless a code was decoded there" do
    text = "=== page 1 ===\nScan to Verify\n=== page 2 ===\nPlain\n=== page 3 ===\nscan code or visit redcross.org\n=== page 4 ===\nPlain"

    assert_equal [ 1, 4 ], Imports::ImageQuality.unread_qr_pages(text, undecoded_pages: [ 4 ], decoded_pages: [ 3 ])
    assert_equal [], Imports::ImageQuality.unread_qr_pages("Scanned with CamScanner", undecoded_pages: [], decoded_pages: [])
    assert_equal [], Imports::ImageQuality.unread_qr_pages(nil, undecoded_pages: [], decoded_pages: [])
  end

  test "a photo that reads fine isn't flagged, however soft it is" do
    assert_equal [], Imports::ImageQuality.flags(item, READ, COMPLETED)
  end

  test "an unread QR code flags it" do
    assert_equal [ "qr_unreadable" ], Imports::ImageQuality.flags(item(unread_qr_pages: [ 1 ]), READ, COMPLETED)
  end

  test "a scan or photo with details unread or an unsure model flags it" do
    [ READ.merge("holder_name" => nil), READ.merge("certificate_name_as_printed" => " "), READ.merge("unreadable" => { "completed_on" => "3/1" }),
      READ.merge("confidence" => 0.59) ].each do |data|
      assert_equal [ "hard_to_read" ], Imports::ImageQuality.flags(item, data, COMPLETED), data.inspect
    end
    assert_equal [ "hard_to_read" ], Imports::ImageQuality.flags(item, READ, Dates.new(completed_on: nil))
    assert_equal [ "hard_to_read" ], Imports::ImageQuality.flags(item(content_type: "application/pdf", ocr_pages: [ 1 ]), READ.merge("holder_name" => nil), COMPLETED)
  end

  test "a PDF with a text layer missing a detail isn't an image problem" do
    assert_equal [], Imports::ImageQuality.flags(item(content_type: "application/pdf"), READ.merge("holder_name" => nil), COMPLETED)
  end
end
