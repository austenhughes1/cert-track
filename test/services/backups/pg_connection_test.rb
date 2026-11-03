require "test_helper"
require_relative "backups_test_support"

class Backups::PgConnectionTest < ActiveSupport::TestCase
  include BackupsTestSupport

  CONFIG = { adapter: "postgresql", host: "db.internal", port: 5432, username: "cert_track",
             password: "s3cret", database: "cert_track_production" }.freeze

  test "builds tool flags without the password" do
    connection = Backups::PgConnection.new(CONFIG)

    assert_equal %w[--host db.internal --port 5432 --username cert_track], connection.connection_args
    assert_equal "cert_track_production", connection.database
    assert_not_includes connection.psql_argv("x").join(" "), "s3cret"
  end

  test "passes the password only through the child environment" do
    assert_equal({ "PGPASSWORD" => "s3cret" }, Backups::PgConnection.new(CONFIG).env)
    assert_equal({}, Backups::PgConnection.new(CONFIG.except(:password)).env)
    assert_equal "require", Backups::PgConnection.new(CONFIG.merge(sslmode: "require")).env["PGSSLMODE"]
  end

  test "omits unset connection settings so libpq defaults apply" do
    connection = Backups::PgConnection.new(database: "cert_track_test", host: nil, username: "")

    assert_empty connection.connection_args
  end

  test "inspect never shows the password" do
    assert_not_includes Backups::PgConnection.new(CONFIG).inspect, "s3cret"
  end

  test "with_database keeps the other settings" do
    copy = Backups::PgConnection.new(CONFIG).with_database("cert_track_restore_check")

    assert_equal "cert_track_restore_check", copy.database
    assert_equal({ "PGPASSWORD" => "s3cret" }, copy.env)
  end

  test "requires a database name" do
    assert_raises(ArgumentError) { Backups::PgConnection.new(CONFIG.except(:database)) }
  end

  test "primary reads the app's database config" do
    assert_equal ActiveRecord::Base.connection_db_config.database, Backups::PgConnection.primary.database
  end

  test "psql runs a script with safely quoted variables" do
    skip_unless_pg_tools

    output = Backups::PgConnection.primary.psql("SELECT :'value' AS value;\n", variables: { value: "it's; DROP" })

    assert_equal "it's; DROP", output.strip
  end

  test "psql raises CommandError when the script fails" do
    skip_unless_pg_tools

    error = assert_raises(Backups::PgConnection::CommandError) do
      Backups::PgConnection.primary.psql("SELECT * FROM no_such_table;\n")
    end
    assert_match "no_such_table", error.message
  end
end
