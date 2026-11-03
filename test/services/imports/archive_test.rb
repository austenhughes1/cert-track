require "test_helper"
require "support/import_samples"

class Imports::ArchiveTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("archive-test-"))
    @dir = @root.join("work").tap(&:mkpath)
    @pdf = ImportSamples.pdf({})
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "a plain upload is one entry, typed and hashed from its bytes" do
    entries, archive = expand(@pdf, "ortiz card.pdf")

    assert_equal 1, entries.size
    entry = entries.first
    assert entry.accepted?
    assert_equal [ "ortiz card.pdf", "application/pdf", @pdf.bytesize, Digest::SHA256.hexdigest(@pdf), false ],
      [ entry.name, entry.content_type, entry.byte_size, entry.sha256, entry.from_zip ]
    assert_equal 1, archive.entries_seen
    assert_nil archive.limit_message
  end

  test "the type comes from the content, not the name" do
    jpeg = ImportSamples.image({}, format: :jpeg)
    assert_equal "image/jpeg", expand(jpeg, "card.pdf").first.first.content_type
    assert_equal "application/pdf", expand(@pdf, "card.jpg").first.first.content_type

    fake, = expand("just some text pretending to be a PDF", "card.pdf")
    assert fake.first.rejected?
    assert_match "Unsupported file type (application/octet-stream)", fake.first.rejection_reason
    assert_equal Digest::SHA256.hexdigest("just some text pretending to be a PDF"), fake.first.sha256
  end

  test "detects every supported image type" do
    formats = { png: "image/png", webp: "image/webp", jpeg: "image/jpeg" }
    formats[:heic] = "image/heic" if ImportSamples.heic_supported?
    formats.each do |format, type|
      entries, = expand(ImportSamples.image({}, format: format), "photo.bin")
      assert_equal type, entries.first.content_type, format
    end

    heic, = expand(file_fixture("certificate.heic").binread, "IMG_0001.HEIC")
    assert_equal "image/heic", heic.first.content_type
  end

  test "HEIC and HEIF brands Marcel misses, and AVIF is not HEIC" do
    box = ->(major, *compatible) { [ 16 + 4 * compatible.size ].pack("N") + "ftyp#{major}\0\0\0\0#{compatible.join}" + "\0" * 8 }

    assert_equal "image/heic", Imports::Archive.heif_type(box.call("heix", "mif1", "heic"))
    assert_equal "image/heic", Imports::Archive.heif_type(box.call("mif1", "heic"))
    assert_equal "image/heif", Imports::Archive.heif_type(box.call("msf1", "iso8"))
    assert_nil Imports::Archive.heif_type(box.call("mif1", "avif"))
    assert_nil Imports::Archive.heif_type(box.call("isom", "mp41"))
    assert_nil Imports::Archive.heif_type("%PDF-1.4")
  end

  test "a zip yields each file with its path inside the zip" do
    zip = ImportSamples.zip(
      "cards/" => nil,
      "cards/ortiz.pdf" => @pdf,
      "cards/chen.png" => ImportSamples.image({ holder: "Li Chen" }, format: :png),
      "garcia.webp" => ImportSamples.image({ holder: "Maria Garcia" }, format: :webp),
      "notes.txt" => "remember to renew"
    )
    entries, archive = expand(zip, "crew.zip")

    assert_equal [ "crew.zip/cards/ortiz.pdf", "crew.zip/cards/chen.png", "crew.zip/garcia.webp", "crew.zip/notes.txt" ],
      entries.map(&:name)
    assert_equal [ "application/pdf", "image/png", "image/webp", nil ], entries.map(&:content_type)
    assert entries.first(3).all?(&:accepted?)
    assert entries.first(3).all?(&:from_zip)
    assert_equal "ortiz.pdf", entries.first.filename
    assert_equal Digest::SHA256.hexdigest(@pdf), entries.first.sha256
    assert_match "Unsupported file type", entries.last.rejection_reason
    assert_equal 4, archive.entries_seen
  end

  test "entry files exist inside the block and are deleted after it" do
    zip = ImportSamples.zip("a.pdf" => @pdf, "b.pdf" => ImportSamples.pdf({ holder: "Li Chen" }))
    paths = []
    write(zip, "crew.zip").then do |path|
      Imports::Archive.new(@dir).expand(path, name: "crew.zip") do |entry|
        assert File.exist?(entry.path)
        assert_equal entry.byte_size, File.size(entry.path)
        assert_equal @dir.to_s, File.dirname(entry.path)
        paths << entry.path
      end
    end

    assert_equal 2, paths.uniq.size
    paths.each { |path| assert_not File.exist?(path) }
    assert_empty @dir.children
  end

  test "skips Mac, Windows and hidden junk without counting it" do
    zip = ImportSamples.zip(
      "__MACOSX/._ortiz.pdf" => "AppleDouble", "__MACOSX/cards/x.pdf" => @pdf, ".DS_Store" => "\0\0\0\1Bud1",
      "cards/.DS_Store" => "x", "cards/Thumbs.db" => "x", "Desktop.ini" => "x", "cards/.hidden.pdf" => @pdf,
      ".git/config" => "x", "cards/ortiz.pdf" => @pdf
    )
    entries, archive = expand(zip, "crew.zip")

    assert_equal [ "crew.zip/cards/ortiz.pdf" ], entries.map(&:name)
    assert_equal 1, archive.entries_seen
    assert_equal 8, archive.skipped.size
    assert_includes archive.skipped, "crew.zip/__MACOSX/._ortiz.pdf"

    top_level, = expand("\0\0\0\1Bud1", ".DS_Store")
    assert_empty top_level
  end

  test "zip-slip and absolute paths are rejected and nothing is written outside the work folder" do
    zip = ImportSamples.zip(
      "../evil.pdf" => @pdf, "cards/../../evil.pdf" => @pdf, "/tmp/evil.pdf" => @pdf, "C:/evil.pdf" => @pdf,
      "..\\other\\evil.pdf" => @pdf, "../.DS_Store" => "x", "cards/ok.pdf" => @pdf
    )
    system_tmp_evil = File.exist?("/tmp/evil.pdf")
    entries, archive = expand(zip, "crew.zip")

    rejected = entries.select(&:rejected?)
    assert_equal [ "crew.zip/../evil.pdf", "crew.zip/cards/../../evil.pdf", "crew.zip//tmp/evil.pdf", "crew.zip/C:/evil.pdf",
                   "crew.zip/../other/evil.pdf", "crew.zip/../.DS_Store" ], rejected.map(&:name)
    assert rejected.all? { |entry| entry.rejection_reason.include?("zip-slip") }
    assert rejected.all? { |entry| entry.path.nil? && entry.sha256.nil? }
    assert_equal [ "crew.zip/cards/ok.pdf" ], entries.select(&:accepted?).map(&:name)
    assert_equal 7, archive.entries_seen

    assert_equal [ "upload", "work" ], @root.children.map { |child| child.basename.to_s }.sort
    assert_empty Dir.glob(@root.join("**", "*evil*").to_s)
    assert_empty Dir.glob(@root.parent.join("*evil*").to_s)
    assert_equal system_tmp_evil, File.exist?("/tmp/evil.pdf")
  end

  test "nested zips two levels down are read; a third level is rejected" do
    two, archive = expand(ImportSamples.nested_zip(2, "card.pdf" => @pdf), "outer.zip")
    assert_equal [ "outer.zip/level1.zip/level2.zip/card.pdf" ], two.map(&:name)
    assert two.first.accepted?
    assert_equal 1, archive.entries_seen

    three, archive = expand(ImportSamples.nested_zip(3, "card.pdf" => @pdf), "outer.zip")
    assert_equal [ "outer.zip/level1.zip/level2.zip/level3.zip" ], three.map(&:name)
    assert_match "Zip nested more than 2 levels deep", three.first.rejection_reason
    assert_match(/\A\h{64}\z/, three.first.sha256)
    assert_equal 1, archive.entries_seen
  end

  test "max_zip_depth comes from the config" do
    Imports::Config.with(max_zip_depth: 0) do
      entries, = expand(ImportSamples.nested_zip(1, "card.pdf" => @pdf), "outer.zip")
      assert_equal [ "outer.zip/level1.zip" ], entries.map(&:name)
      assert entries.first.rejected?
    end
  end

  test "stops at max_entries and accounts for the cut-off file and later uploads" do
    zip = ImportSamples.zip((1..5).to_h { |n| [ "card#{n}.pdf", ImportSamples.pdf({ number: "N-#{n}" }) ] })
    archive = Imports::Archive.new(@dir, max_entries: 3)
    entries = []
    archive.expand(write(zip, "crew.zip"), name: "crew.zip") { |entry| entries << entry }

    assert_equal 3, entries.count(&:accepted?)
    assert_equal [ "crew.zip/card4.pdf" ], entries.select(&:rejected?).map(&:name)
    assert_match "Over the 3-file limit", entries.last.rejection_reason
    assert_match "Stopped at the 3-file limit for one batch: crew.zip/card4.pdf", archive.limit_message
    assert archive.limit_reached?

    later = []
    archive.expand(write(@pdf, "late.pdf"), name: "late.pdf") { |entry| later << entry }
    assert_equal [ "late.pdf" ], later.map(&:name)
    assert_match "Not imported", later.first.rejection_reason
    assert_equal 5, archive.entries_seen
  end

  test "a zip listing more records than the batch allows is rejected unopened, junk included" do
    junk = (1..20).to_h { |n| [ "__MACOSX/#{n}", "x" ] }
    zip = ImportSamples.zip(junk.merge("cards/" => nil, "cards/ortiz.pdf" => @pdf))
    entries, archive = expand(zip, "crew.zip", max_entries: 3) # 15 records: 3 x RECORDS_PER_ENTRY

    assert_equal [ "crew.zip" ], entries.map(&:name)
    assert_match "This zip lists 22 entries, over the 15-entry zip limit for one batch (zip-bomb guard)", entries.sole.rejection_reason
    assert_match "Stopped at the 15-entry zip limit for one batch (zip-bomb guard): crew.zip lists 22 entries", archive.limit_message
    assert_empty archive.skipped, "never opened, so nothing was walked"
    assert_equal [ 1, 0 ], [ archive.entries_seen, archive.zip_records ]

    later = []
    archive.expand(write(@pdf, "late.pdf"), name: "late.pdf") { |entry| later << entry }
    assert_match "Not imported", later.sole.rejection_reason
  end

  test "folders, junk and nested zips all draw on one record budget for the batch" do
    nested = (1..4).to_h { |n| [ "n#{n}.zip", ImportSamples.zip("__MACOSX/a" => "x", "__MACOSX/b" => "x") ] }
    zip = ImportSamples.zip({ "card.pdf" => @pdf }.merge(nested))
    entries, archive = expand(zip, "crew.zip", max_zip_records: 10)

    # crew.zip holds 5 records, n1 and n2 two each (9); n3's two don't fit, n4 is never reached.
    assert_equal [ "crew.zip/card.pdf", "crew.zip/n3.zip" ], entries.map(&:name)
    assert entries.first.accepted?
    assert_match "This zip lists 2 entries, over the 10-entry zip limit", entries.last.rejection_reason
    assert archive.limit_reached?
    assert_equal 9, archive.zip_records
    assert_equal 4, archive.skipped.size
    assert_equal 2, archive.entries_seen
  end

  test "a zip whose end record declares millions of entries is refused before its directory is read" do
    zip = declaring_entries(ImportSamples.zip("card.pdf" => @pdf), 5_000_000) # Zip64 end record
    assert_equal 5_000_000, Zip::File.count_entries(write(zip, "bomb.zip"))

    entries, archive = expand(zip, "bomb.zip")

    assert_match "This zip lists 5,000,000 entries, over the 10,000-entry zip limit", entries.sole.rejection_reason
    assert_match "zip-bomb guard", archive.limit_message
    assert_equal 0, archive.zip_records
  end

  test "stops past max_uncompressed_bytes, counted across entries" do
    zip = ImportSamples.zip("a.pdf" => "%PDF-1.4\n" + "a" * 600, "b.pdf" => "%PDF-1.4\n" + "b" * 600, "c.pdf" => @pdf)
    archive = Imports::Archive.new(@dir, max_uncompressed_bytes: 1_000)
    entries = []
    archive.expand(write(zip, "crew.zip"), name: "crew.zip") { |entry| entries << entry }

    assert_equal [ "crew.zip/a.pdf", "crew.zip/b.pdf" ], entries.map(&:name)
    assert entries.first.accepted?
    assert_match "Over the 1000 Bytes uncompressed limit", entries.last.rejection_reason
    assert_match "zip-bomb guard", archive.limit_message
    assert_empty @dir.children
  end

  test "counts the bytes actually inflated, not the size the header declares" do
    bomb = ImportSamples.declare_size(ImportSamples.zip("bomb.pdf" => "%PDF-1.4\n" + "\0" * 500_000), "bomb.pdf", 100)
    assert_equal [ 100 ], Zip::File.open_buffer(StringIO.new(bomb)).entries.map(&:size)

    archive = Imports::Archive.new(@dir, max_uncompressed_bytes: 10_000)
    entries = []
    archive.expand(write(bomb, "bomb.zip"), name: "bomb.zip") { |entry| entries << entry }

    assert_equal 1, entries.size
    assert entries.first.rejected?
    assert_match "uncompressed limit", entries.first.rejection_reason
    assert_operator archive.bytes_read, :>, 10_000
    assert_operator archive.bytes_read, :<=, 10_000 + Imports::Archive::CHUNK_SIZE # stopped at the first chunk past it
    assert_empty @dir.children
  end

  test "a declared size over the limit is refused without reading" do
    zip = ImportSamples.declare_size(ImportSamples.zip("a.pdf" => @pdf), "a.pdf", 5_000_000)
    archive = Imports::Archive.new(@dir, max_uncompressed_bytes: 1_000_000)
    entries = []
    archive.expand(write(zip, "crew.zip"), name: "crew.zip") { |entry| entries << entry }

    assert entries.first.rejected?
    assert_equal 0, archive.bytes_read
  end

  test "a corrupt zip is one rejected entry" do
    entries, archive = expand("PK\x03\x04 this is not really a zip", "crew.zip")

    assert_equal [ "crew.zip" ], entries.map(&:name)
    assert_match "Couldn't open this zip", entries.first.rejection_reason
    assert_equal 1, archive.entries_seen
  end

  test "a password-protected entry is rejected" do
    buffer = Zip::OutputStream.write_buffer(StringIO.new(+""), encrypter: Zip::TraditionalEncrypter.new("secret")) do |zip|
      zip.put_next_entry("locked.pdf")
      zip.write(@pdf)
    end
    entries, = expand(buffer.string, "locked.zip")

    assert_equal [ "locked.zip/locked.pdf" ], entries.map(&:name)
    assert_match "Password-protected", entries.first.rejection_reason
  end

  test "entry names that aren't UTF-8 are read as code page 437, and long names are shortened" do
    long = "#{"folder/" * 60}ortiz.pdf"
    zip = ImportSamples.zip("r\x82sum\x82.pdf".b => @pdf, long => @pdf)
    entries, = expand(zip, "crew.zip")

    assert_equal "crew.zip/résumé.pdf", entries.first.name
    assert_equal Encoding::UTF_8, entries.first.name.encoding
    assert_equal 255, entries.last.name.length
    assert entries.last.name.end_with?("folder/ortiz.pdf")
  end

  private
    # Expands bytes saved as name; returns [entries, archive].
    def expand(bytes, name, **limits)
      archive = Imports::Archive.new(@dir, **limits)
      entries = []
      archive.expand(write(bytes, name), name: name) { |entry| entries << entry }
      [ entries, archive ]
    end

    def write(bytes, name)
      ImportSamples.write(@root.join("upload"), SecureRandom.hex(4) + File.extname(name.to_s), bytes).to_s
    end

    # zip_bytes with its end record replaced by a Zip64 one declaring count entries (and a
    # central directory big enough to hold them, so rubyzip has nothing to warn about).
    def declaring_entries(zip_bytes, count)
      bytes = zip_bytes.b
      at = bytes.rindex("PK\x05\x06".b)
      _, _, _, _, _, size, offset, = bytes.byteslice(at, 22).unpack("VvvvvVVv")
      body = bytes.byteslice(0, at)
      zip64 = [ 0x06064b50, 44, 45, 45, 0, 0, count, count, [ size, count * 46 ].max, offset ].pack("VQ<vvVVQ<Q<Q<Q<")
      locator = [ 0x07064b50, 0, body.bytesize, 1 ].pack("VVQ<V")
      body + zip64 + locator + [ 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0 ].pack("VvvvvVVv")
    end
end
