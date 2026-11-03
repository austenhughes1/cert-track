require "test_helper"
require "rake"
require_relative "../services/backups/backups_test_support"

class BackupsTaskTest < ActiveSupport::TestCase
  include BackupsTestSupport

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("certtrack:restore_latest")
    @scratch_databases = []
  end

  teardown do
    @scratch_databases.each { |name| drop_database(name) }
  end

  test "certtrack:backup_now runs the backup job inline" do
    skip_unless_pg_tools
    uploads = {}

    output, = capture_io do
      with_backup_key do
        with_stubbed_r2(put_object: capture_upload(uploads), list_objects_v2: list_response([])) do
          Rake::Task["certtrack:backup_now"].execute
        end
      end
    end

    key = uploads.keys.sole
    assert_match Backups::Storage::KEY_PATTERN, key
    assert_includes output, "Uploaded #{key}"
    assert_includes decrypt_and_gunzip(uploads[key]), "CREATE TABLE public.users"
  end

  test "certtrack:restore_latest restores into TARGET_DATABASE and prints row counts" do
    skip_unless_pg_tools
    key, bytes = encrypted_backup_of_test_database
    target = scratch_database_name.tap { |name| @scratch_databases << name }

    output, = capture_io do
      with_env("TARGET_DATABASE" => target, "FORCE" => nil, "KEY" => nil) do
        with_backup_key do
          with_stubbed_r2(list_objects_v2: list_response([ key ]), get_object: { body: bytes }) do
            Rake::Task["certtrack:restore_latest"].execute
          end
        end
      end
    end

    assert_includes output, "Restored #{key} into #{target}"
    assert_match(/^\s+users\s+#{User.count}$/, output)
    assert table_exists?(target, "users")
  end

  test "certtrack:restore_latest refuses the app's own database without FORCE=1" do
    own = ActiveRecord::Base.connection_db_config.database

    _, errors = capture_io do
      with_env("TARGET_DATABASE" => own, "FORCE" => nil) do
        assert_raises(SystemExit) { Rake::Task["certtrack:restore_latest"].execute }
      end
    end

    assert_match "Refusing to restore over #{own}", errors
  end
end
