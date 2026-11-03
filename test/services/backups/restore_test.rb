require "test_helper"
require_relative "backups_test_support"

class Backups::RestoreTest < ActiveSupport::TestCase
  include BackupsTestSupport

  setup { @scratch_databases = [] }

  teardown do
    @scratch_databases.each do |name|
      drop_database(name)
      drop_database(Backups::Restore.staging_database_for(name))
    end
  end

  test "restores the newest backup into a new scratch database and counts key tables" do
    skip_unless_pg_tools
    key, bytes = encrypted_backup_of_test_database
    older = Backups::Storage.key_for(Time.utc(2026, 1, 1))
    client = stub_s3_client(list_objects_v2: list_response([ key, older ]), get_object: { body: bytes })

    result = restore(client:)

    assert_equal key, result.key
    assert_equal @scratch_databases.last, result.database
    assert table_exists?(result.database, "users")
    assert table_exists?(result.database, "sessions")
    assert_equal({ "users" => User.count }, result.row_counts.slice("users"))
    assert_equal [ key ], client.api_requests.select { |r| r[:operation_name] == :get_object }.map { |r| r[:params][:key] }
  end

  test "can restore again over an existing target" do
    skip_unless_pg_tools
    key, bytes = encrypted_backup_of_test_database
    client = stub_s3_client(list_objects_v2: list_response([ key ]), get_object: { body: bytes })
    name = scratch_database

    restore(client:, target_database: name)
    result = restore(client:, target_database: name)

    assert_equal User.count, result.row_counts["users"]
  end

  # The rebuild runbook restores over a database that db:prepare loaded from a newer
  # schema.rb, which can have tables (and foreign keys) the backup knows nothing about.
  test "replaces a target whose schema is newer than the backup" do
    skip_unless_pg_tools
    key, bytes = encrypted_backup_of_test_database
    client = stub_s3_client(list_objects_v2: list_response([ key ]), get_object: { body: bytes })
    name = scratch_database
    restore(client:, target_database: name)
    run_sql(name, <<~SQL)
      CREATE TABLE public.newer_things (id bigserial PRIMARY KEY, user_id bigint REFERENCES public.users (id));
      CREATE TABLE public.loose_things (id bigserial PRIMARY KEY);
      INSERT INTO public.schema_migrations (version) VALUES ('29991231000000');
    SQL

    result = restore(client:, target_database: name)

    assert_equal User.count, result.row_counts["users"]
    assert_not table_exists?(name, "newer_things")
    assert_not table_exists?(name, "loose_things")
    assert_equal "0", run_sql(name, "SELECT count(*) FROM schema_migrations WHERE version = '29991231000000';").strip
    assert_not database_exists?(Backups::Restore.staging_database_for(name))
  end

  test "restores a specific key when given one" do
    skip_unless_pg_tools
    key, bytes = encrypted_backup_of_test_database
    client = stub_s3_client(get_object: { body: bytes })

    result = restore(client:, key:)

    assert_equal key, result.key
    assert_empty client.api_requests.select { |r| r[:operation_name] == :list_objects_v2 }
  end

  test "refuses the app's own database unless forced, before touching storage" do
    client = stub_s3_client

    error = assert_raises(Backups::Restore::Error) do
      restore(client:, target_database: ActiveRecord::Base.connection_db_config.database)
    end

    assert_match "FORCE=1", error.message
    assert_empty client.api_requests
  end

  test "refuses names that are not plain database names" do
    error = assert_raises(Backups::Restore::Error) do
      restore(client: stub_s3_client, target_database: "host=elsewhere dbname=x")
    end
    assert_match "not a plain database name", error.message
  end

  test "fails clearly when the bucket has no backups" do
    error = assert_raises(Backups::Restore::Error) { restore(client: stub_s3_client) }
    assert_match "No backups found", error.message
  end

  test "a tampered backup fails before any database is created" do
    skip_unless_pg_tools
    key, bytes = encrypted_backup_of_test_database
    bytes.setbyte(100, bytes.getbyte(100) ^ 0x01)
    client = stub_s3_client(list_objects_v2: list_response([ key ]), get_object: { body: bytes })

    error = assert_raises(Backups::Restore::Error) { restore(client:) }

    assert_match "failed authentication", error.message
    assert_not database_exists?(@scratch_databases.last)
  end

  test "a backup encrypted with another key is rejected" do
    skip_unless_pg_tools
    key, bytes = encrypted_backup_of_test_database
    client = stub_s3_client(list_objects_v2: list_response([ key ]), get_object: { body: bytes })

    assert_raises(Backups::Restore::Error) do
      restore(client:, encryptor: Backups::Encryptor.new(key: SecureRandom.random_bytes(32)))
    end
  end

  test "SQL errors abort the restore and roll it back" do
    skip_unless_pg_tools
    bytes = encrypt_sql("CREATE TABLE public.users (id bigint);\nSELECT * FROM missing_table;\n")
    client = stub_s3_client(list_objects_v2: list_response([ Backups::Storage.key_for(Time.current) ]),
                            get_object: { body: bytes })

    error = assert_raises(Backups::Restore::Error) { restore(client:) }

    assert_match "missing_table", error.message
    assert_not database_exists?(@scratch_databases.last)
    assert_not database_exists?(Backups::Restore.staging_database_for(@scratch_databases.last))
  end

  test "a failed restore leaves an existing target as it was" do
    skip_unless_pg_tools
    name = scratch_database
    Backups::PgConnection.primary.psql(%(CREATE DATABASE :"name";\n), variables: { name: })
    run_sql(name, "CREATE TABLE public.keep_me (id int); INSERT INTO public.keep_me VALUES (1);")
    bytes = encrypt_sql("CREATE TABLE public.users (id bigint);\nSELECT * FROM missing_table;\n")
    client = stub_s3_client(list_objects_v2: list_response([ Backups::Storage.key_for(Time.current) ]),
                            get_object: { body: bytes })

    assert_raises(Backups::Restore::Error) { restore(client:, target_database: name) }

    assert_equal "1", run_sql(name, "SELECT count(*) FROM public.keep_me;").strip
    assert_not table_exists?(name, "users")
    assert_not database_exists?(Backups::Restore.staging_database_for(name))
  end

  test "refuses names too long to leave room for the staging database's name" do
    error = assert_raises(Backups::Restore::Error) do
      restore(client: stub_s3_client, target_database: "a" * 54)
    end

    assert_match "not a plain database name", error.message
    assert_equal 63, Backups::Restore.staging_database_for("a" * 53).length
  end

  private
    def restore(client:, target_database: scratch_database, encryptor: backup_encryptor, **options)
      Backups::Restore.new(target_database:, storage: Backups::Storage.new(client:, bucket: "b"), encryptor:,
                           **options).call
    end

    # A fresh scratch name, dropped in teardown.
    def scratch_database
      scratch_database_name.tap { |name| @scratch_databases << name }
    end

    def encrypt_sql(sql)
      output = StringIO.new("".b)
      backup_encryptor.encrypt(output) { |writer| writer.write(Zlib.gzip(sql)) }
      output.string
    end

    def run_sql(database, sql)
      Backups::PgConnection.primary.psql(sql, database:)
    end

    def database_exists?(name)
      Backups::PgConnection.primary
        .psql("SELECT count(*) FROM pg_database WHERE datname = :'name';\n", variables: { name: })
        .strip == "1"
    end
end
