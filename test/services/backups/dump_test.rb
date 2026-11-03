require "test_helper"
require_relative "backups_test_support"

class Backups::DumpTest < ActiveSupport::TestCase
  include BackupsTestSupport

  test "runs pg_dump as plain SQL without owners or privileges, password kept off the command line" do
    connection = Backups::PgConnection.new(host: "db", port: 5432, username: "cert_track", password: "s3cret",
                                           database: "cert_track_production")

    argv = Backups::Dump.new(connection:).argv

    assert_equal "pg_dump", argv.first
    assert_includes argv, "--format=plain"
    assert_includes argv, "--no-owner"
    assert_includes argv, "--no-privileges"
    assert_equal %w[--dbname cert_track_production], argv.last(2)
    assert_not_includes argv.join(" "), "s3cret"
  end

  test "streams the test database's schema and data" do
    skip_unless_pg_tools

    sql = Backups::Dump.new.write_to(StringIO.new).string

    assert_includes sql, "CREATE TABLE public.users"
    assert_includes sql, "COPY public.users"
    assert_includes sql, users(:admin).email_address
  end

  test "raises when pg_dump exits non-zero" do
    skip_unless_pg_tools
    connection = Backups::PgConnection.primary.with_database("cert_track_missing_#{SecureRandom.hex(4)}")

    error = assert_raises(Backups::Dump::Error) { Backups::Dump.new(connection:).write_to(StringIO.new) }
    assert_match "does not exist", error.message
  end
end
