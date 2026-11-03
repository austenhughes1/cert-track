require "openssl"

module Backups
  # Streaming AES-256-GCM encryption for database backups.
  #
  # File format ("CTBK1"):
  #
  #   bytes 0..4    magic "CTBK1" (also bound to the ciphertext as GCM additional authenticated data)
  #   bytes 5..16   12-byte random IV, fresh for every file
  #   bytes 17..-17 ciphertext (the gzipped SQL dump)
  #   last 16 bytes GCM authentication tag
  #
  # Data moves through in chunks, so a dump never has to fit in memory. Decryption
  # writes plaintext before the tag can be checked; callers must treat the output as
  # untrusted until #decrypt returns (Restore decrypts to a temp file first).
  class Encryptor
    class Error < StandardError; end
    class FormatError < Error; end
    class AuthenticationError < Error; end
    class InvalidKeyError < Error; end

    MAGIC = "CTBK1".b.freeze
    IV_LENGTH = 12
    TAG_LENGTH = 16
    KEY_LENGTH = 32
    CIPHER = "aes-256-gcm".freeze
    CHUNK_SIZE = 1024 * 1024

    # IO-like sink yielded by #encrypt; works with Zlib::GzipWriter and IO.copy_stream.
    class Writer
      def initialize(cipher, output)
        @cipher = cipher
        @output = output
      end

      def write(*chunks)
        chunks.sum do |chunk|
          data = chunk.to_s.b
          @output.write(@cipher.update(data)) unless data.empty?
          data.bytesize
        end
      end

      def <<(chunk)
        write(chunk)
        self
      end
    end

    # The 32-byte key from credentials.backup_encryption_key (64 hex characters).
    def self.default_key
      hex = Rails.application.credentials.backup_encryption_key.to_s
      unless hex.match?(/\A\h{#{KEY_LENGTH * 2}}\z/o)
        raise InvalidKeyError, "credentials.backup_encryption_key must be #{KEY_LENGTH * 2} hex characters"
      end

      [ hex ].pack("H*")
    end

    def initialize(key: self.class.default_key, chunk_size: CHUNK_SIZE)
      raise InvalidKeyError, "backup key must be #{KEY_LENGTH} bytes" unless key.to_s.bytesize == KEY_LENGTH

      @key = key.b
      @chunk_size = chunk_size
    end

    # Writes the header to output, yields a Writer that encrypts everything written to
    # it, then appends the authentication tag.
    def encrypt(output)
      iv = SecureRandom.random_bytes(IV_LENGTH)
      cipher = build_cipher(:encrypt, iv)
      output.write(MAGIC, iv)
      yield Writer.new(cipher, output)
      output.write(cipher.final, cipher.auth_tag(TAG_LENGTH))
      output
    end

    # Reads a CTBK1 stream from input and writes the plaintext to output. Raises
    # FormatError for a foreign or truncated file, AuthenticationError for a wrong key
    # or tampered bytes.
    def decrypt(input, output)
      header = input.read(MAGIC.bytesize + IV_LENGTH).to_s.b
      unless header.bytesize == MAGIC.bytesize + IV_LENGTH && header.start_with?(MAGIC)
        raise FormatError, "not a CertTrack backup (bad magic)"
      end

      cipher = build_cipher(:decrypt, header.byteslice(MAGIC.bytesize, IV_LENGTH))
      tag = decrypt_all_but_tag(input, output, cipher)
      raise FormatError, "backup is truncated" if tag.bytesize < TAG_LENGTH

      cipher.auth_tag = tag
      output.write(cipher.final)
      output
    rescue OpenSSL::Cipher::CipherError
      raise AuthenticationError, "backup failed authentication (wrong key or tampered file)"
    end

    def encrypt_file(source_path, destination_path)
      File.open(source_path, "rb") do |input|
        File.open(destination_path, "wb") do |output|
          encrypt(output) { |writer| IO.copy_stream(input, writer) }
        end
      end
    end

    def decrypt_file(source_path, destination_path)
      File.open(source_path, "rb") do |input|
        File.open(destination_path, "wb") { |output| decrypt(input, output) }
      end
    end

    private
      def build_cipher(mode, iv)
        OpenSSL::Cipher.new(CIPHER).tap do |cipher|
          cipher.public_send(mode)
          cipher.key = @key
          cipher.iv = iv
          cipher.auth_data = MAGIC
        end
      end

      # Decrypts the stream while holding back the last TAG_LENGTH bytes, which it returns.
      def decrypt_all_but_tag(input, output, cipher)
        pending = "".b
        while (chunk = input.read(@chunk_size))
          pending << chunk
          next if pending.bytesize <= TAG_LENGTH

          output.write(cipher.update(pending.byteslice(0, pending.bytesize - TAG_LENGTH)))
          pending = pending.byteslice(-TAG_LENGTH, TAG_LENGTH)
        end
        pending
      end
  end
end
