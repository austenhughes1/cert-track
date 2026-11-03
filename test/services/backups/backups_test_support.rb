require "aws-sdk-s3"

# Shared helpers for the backup tests. Required by them; not a test file itself.
module BackupsTestSupport
  TEST_KEY_HEX = "00112233445566778899aabbccddeeff" * 2
  R2_ENV = {
    "R2_ACCOUNT_ID" => "test-account",
    "R2_ACCESS_KEY_ID" => "test-access-key-id",
    "R2_SECRET_ACCESS_KEY" => "test-secret-access-key",
    "R2_BACKUP_BUCKET" => "certtrack-backups-test"
  }.freeze

  def backup_key
    [ TEST_KEY_HEX ].pack("H*")
  end

  def backup_encryptor(**options)
    Backups::Encryptor.new(key: backup_key, **options)
  end

  # Stubbed S3 client that records put_object bodies in `uploads` (key => bytes).
  def stub_s3_client(uploads: {}, **responses)
    Aws::S3::Client.new(stub_responses: true).tap do |client|
      client.stub_responses(:put_object, capture_upload(uploads))
      client.stub_responses(:list_objects_v2, { contents: [] })
      responses.each { |operation, response| client.stub_responses(operation, response) }
    end
  end

  def capture_upload(uploads)
    lambda do |context|
      body = context.params[:body]
      body.rewind
      uploads[context.params[:key]] = body.read.b
      {}
    end
  end

  def list_response(keys)
    { contents: keys.map { |key| { key: } } }
  end

  # Code that builds its own client (the job, the rake tasks) gets a stubbed one.
  def with_stubbed_r2(responses)
    previous = R2_ENV.keys.index_with { |name| ENV[name] }
    ENV.update(R2_ENV)
    Aws.config[:s3] = { stub_responses: responses }
    yield
  ensure
    Aws.config.delete(:s3)
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # The app reads the key from credentials, which CI cannot decrypt, so swap in a known one.
  def with_backup_key(hex = TEST_KEY_HEX)
    original = Rails.application.credentials
    Rails.application.credentials = ActiveSupport::OrderedOptions.new.merge!(backup_encryption_key: hex)
    yield
  ensure
    Rails.application.credentials = original
  end

  def with_env(values)
    previous = values.keys.index_with { |name| ENV[name] }
    values.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    yield
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def skip_unless_pg_tools
    missing = %w[pg_dump psql].reject { |command| on_path?(command) }
    skip "#{missing.to_sentence} not on PATH; skipping backup integration test" if missing.any?

    client = `pg_dump --version`[/\d+/].to_i
    server = ActiveRecord::Base.connection.database_version / 10_000
    skip "pg_dump #{client} cannot dump a PostgreSQL #{server} server; install postgresql-client-#{server}" if client < server
  end

  # A real encrypted backup of the test database: [key, bytes].
  def encrypted_backup_of_test_database
    uploads = {}
    storage = Backups::Storage.new(client: stub_s3_client(uploads:), bucket: "test")
    key = Backups::Create.new(storage:, encryptor: backup_encryptor).call.key
    [ key, uploads.fetch(key) ]
  end

  def decrypt_and_gunzip(bytes)
    compressed = backup_encryptor.decrypt(StringIO.new(bytes), StringIO.new("".b)).string
    Zlib.gunzip(compressed)
  end

  def scratch_database_name
    "cert_track_restore_test#{ENV["TEST_DB_SUFFIX"]}_#{SecureRandom.hex(4)}"
  end

  def drop_database(name)
    raise ArgumentError, "refusing to drop #{name}" unless name.start_with?("cert_track_restore_test")
    return unless on_path?("psql")

    Backups::PgConnection.primary.psql(%(DROP DATABASE IF EXISTS :"name" WITH (FORCE);\n), variables: { name: })
  end

  def table_exists?(database, table)
    Backups::PgConnection.primary
      .psql("SELECT to_regclass(:'table') IS NOT NULL;\n", database:, variables: { table: "public.#{table}" })
      .strip == "t"
  end

  private
    def on_path?(command)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, command)) }
    end
end
