require "test_helper"
require "vips"
require "support/import_samples"

class Imports::ContentDigestTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir("content-digest-test") }
  teardown { FileUtils.remove_entry(@dir) }

  def digest(path, type)
    Imports::ContentDigest.new(path, content_type: type).call
  end

  test "a re-saved image with other bytes has the same digest; another image doesn't" do
    original = Vips::Image.new_from_file(file_fixture("qr/redcross_qr.png").to_s)
    original.pngsave(path("light.png"), compression: 1)
    original.pngsave(path("heavy.png"), compression: 9)
    assert_not_equal File.binread(path("light.png")), File.binread(path("heavy.png"))

    assert_equal digest(path("light.png"), "image/png"), digest(path("heavy.png"), "image/png")
    assert_not_equal digest(path("light.png"), "image/png"), digest(file_fixture("qr/unrelated_qr.png"), "image/png")
  end

  test "two people's certificates of one template differ, however alike" do
    File.binwrite(path("juan.pdf"), ImportSamples.pdf({ holder: "Juan A. Ortiz" }))
    File.binwrite(path("li.pdf"), ImportSamples.pdf({ holder: "Li Chen" }))
    File.binwrite(path("juan_again.pdf"), ImportSamples.pdf({ holder: "Juan A. Ortiz" }))

    assert_not_equal digest(path("juan.pdf"), "application/pdf"), digest(path("li.pdf"), "application/pdf")
    assert_equal digest(path("juan.pdf"), "application/pdf"), digest(path("juan_again.pdf"), "application/pdf")
  end

  test "a file it can't read has no digest, without raising" do
    File.write(path("broken.png"), "not an image")
    File.write(path("broken.pdf"), "not a pdf")

    assert_nil digest(path("broken.png"), "image/png")
    assert_nil digest(path("broken.pdf"), "application/pdf")
  end

  private
    def path(name) = File.join(@dir, name)
end
