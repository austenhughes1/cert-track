namespace :certtrack do
  desc "Back up the database to R2 now (runs Backups::DatabaseJob inline)"
  task backup_now: :environment do
    key = Backups::DatabaseJob.perform_now
    puts "Uploaded #{key}"
  end

  desc "Restore the newest R2 backup into TARGET_DATABASE (default cert_track_restore_check). " \
       "KEY=db/… picks another backup; FORCE=1 allows overwriting this app's own database"
  task restore_latest: :environment do
    restore = Backups::Restore.new(
      target_database: ENV.fetch("TARGET_DATABASE", Backups::Restore::DEFAULT_TARGET),
      force: ENV["FORCE"] == "1",
      key: ENV["KEY"].presence
    )

    begin
      result = restore.call
    rescue Backups::Restore::Error => e
      abort "Restore failed: #{e.message}"
    end

    puts "Restored #{result.key} into #{result.database}"
    width = result.row_counts.keys.map(&:length).max.to_i
    result.row_counts.each { |table, count| puts "  #{table.ljust(width)}  #{count}" }
  end
end
