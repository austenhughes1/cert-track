require "test_helper"
require_relative "backups_test_support"

class Backups::EncryptorTest < ActiveSupport::TestCase
  include BackupsTestSupport

  HEADER_BYTES = Backups::Encryptor::MAGIC.bytesize + Backups::Encryptor::IV_LENGTH

  setup do
    @encryptor = backup_encryptor(chunk_size: 1024)
    @plaintext = SecureRandom.random_bytes(10 * 1024 + 123)
  end

  test "round-trips a file larger than many chunks" do
    ciphertext = encrypt(@plaintext)

    assert ciphertext.start_with?("CTBK1")
    assert_equal HEADER_BYTES + @plaintext.bytesize + Backups::Encryptor::TAG_LENGTH, ciphertext.bytesize
    assert_not_includes ciphertext, @plaintext.byteslice(100, 64)
    assert_equal @plaintext, decrypt(ciphertext)
  end

  test "round-trips through the file helpers and IO.copy_stream" do
    Dir.mktmpdir do |dir|
      paths = %w[plain enc out].index_with { |name| File.join(dir, name) }
      File.binwrite(paths["plain"], @plaintext)

      @encryptor.encrypt_file(paths["plain"], paths["enc"])
      @encryptor.decrypt_file(paths["enc"], paths["out"])

      assert_equal @plaintext, File.binread(paths["out"])
    end
  end

  test "round-trips an empty stream" do
    assert_equal "", decrypt(encrypt(""))
  end

  test "uses a fresh IV for every file" do
    first = encrypt(@plaintext)
    second = encrypt(@plaintext)

    assert_not_equal first.byteslice(0, HEADER_BYTES), second.byteslice(0, HEADER_BYTES)
    assert_not_equal first, second
  end

  test "rejects tampered ciphertext" do
    ciphertext = encrypt(@plaintext)
    ciphertext.setbyte(HEADER_BYTES + 5000, ciphertext.getbyte(HEADER_BYTES + 5000) ^ 0x01)

    assert_raises(Backups::Encryptor::AuthenticationError) { decrypt(ciphertext) }
  end

  test "rejects a tampered authentication tag" do
    ciphertext = encrypt(@plaintext)
    ciphertext.setbyte(-1, ciphertext.getbyte(-1) ^ 0x80)

    assert_raises(Backups::Encryptor::AuthenticationError) { decrypt(ciphertext) }
  end

  test "rejects a tampered IV" do
    ciphertext = encrypt(@plaintext)
    ciphertext.setbyte(6, ciphertext.getbyte(6) ^ 0x01)

    assert_raises(Backups::Encryptor::AuthenticationError) { decrypt(ciphertext) }
  end

  test "rejects the wrong key" do
    ciphertext = encrypt(@plaintext)
    other = Backups::Encryptor.new(key: SecureRandom.random_bytes(32))

    assert_raises(Backups::Encryptor::AuthenticationError) do
      other.decrypt(StringIO.new(ciphertext), StringIO.new("".b))
    end
  end

  test "rejects the wrong magic" do
    ciphertext = encrypt(@plaintext)
    ciphertext[0, 5] = "CTBK2"

    error = assert_raises(Backups::Encryptor::FormatError) { decrypt(ciphertext) }
    assert_match "bad magic", error.message
  end

  test "rejects a plain gzip file" do
    assert_raises(Backups::Encryptor::FormatError) { decrypt(Zlib.gzip("SELECT 1;")) }
  end

  test "rejects a truncated file" do
    ciphertext = encrypt(@plaintext)

    assert_raises(Backups::Encryptor::FormatError) { decrypt(ciphertext.byteslice(0, HEADER_BYTES + 10)) }
    assert_raises(Backups::Encryptor::AuthenticationError) { decrypt(ciphertext.byteslice(0, ciphertext.bytesize - 1)) }
  end

  test "requires a 32-byte key" do
    assert_raises(Backups::Encryptor::InvalidKeyError) { Backups::Encryptor.new(key: "short") }
  end

  test "default_key unpacks the hex key from credentials" do
    with_backup_key { assert_equal backup_key, Backups::Encryptor.default_key }
  end

  test "default_key raises without a valid credentials key" do
    with_backup_key(nil) do
      assert_raises(Backups::Encryptor::InvalidKeyError) { Backups::Encryptor.default_key }
    end
    with_backup_key("zz" * 32) do
      assert_raises(Backups::Encryptor::InvalidKeyError) { Backups::Encryptor.default_key }
    end
  end

  private
    # Writes in uneven pieces so chunk boundaries never line up.
    def encrypt(plaintext)
      output = StringIO.new("".b)
      @encryptor.encrypt(output) do |writer|
        0.step(plaintext.bytesize - 1, 700) { |offset| writer.write(plaintext.byteslice(offset, 700)) }
      end
      output.string
    end

    def decrypt(ciphertext)
      @encryptor.decrypt(StringIO.new(ciphertext.b), StringIO.new("".b)).string
    end
end
