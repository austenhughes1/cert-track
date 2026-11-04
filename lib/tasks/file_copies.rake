namespace :certtrack do
  desc "Copy new certificate files from R2 to FILE_COPY_DIR now (runs Backups::FileCopyJob inline)"
  task copy_files_now: :environment do
    begin
      result = Backups::FileCopyJob.perform_now
    rescue Backups::FileCopyStore::DirectoryError => e
      abort "File copy failed: #{e.message}"
    end
    abort "FILE_COPY_DIR is not set, so file copies are off." unless result

    size = ->(bytes) { ActiveSupport::NumberHelper.number_to_human_size(bytes) }
    puts "File copy #{result.outcome}: #{result.copied} copied (#{size.(result.copied_bytes)}), " \
      "#{result.untrashed} back from the trash, #{result.failed} failed, #{result.not_copied} of #{result.kept} not copied yet"
    puts "  Moved to the trash: #{result.trashed}; deleted from the trash: #{result.expired}"
    puts "  Free space: #{size.(result.disk_space.free_bytes)} (copying stops under #{size.(result.disk_space.reserve_bytes)})"
    result.errors.each { |error| puts "  #{error}" }
  end

  desc "Upload files missing from R2 back from the file copies in FILE_COPY_DIR. A dry run; CONFIRM=1 uploads"
  task restore_files: :environment do
    store = Backups::FileCopyStore.configured
    abort "FILE_COPY_DIR is not set, so there are no file copies to restore from." unless store

    confirm = ENV["CONFIRM"] == "1"
    begin
      result = Backups::FileCopyRestore.new(store:, confirm:).call
    rescue Backups::FileCopyStore::DirectoryError => e
      abort "Restore failed: #{e.message}"
    end

    puts confirm ? "Restoring files from #{store.root}" : "Dry run, nothing uploaded (CONFIRM=1 uploads): files in #{store.root}"
    rows = {
      "Blobs in the database" => result.blobs,
      "No copy here (previews, packet zips, raw uploads, not copied yet)" => result.without_copy,
      "Still in storage" => result.in_storage,
      (confirm ? "Uploaded back to storage" : "Missing from storage, would upload") => "#{result.missing} (#{result.from_trash} from the trash)",
      "Copies that failed the checksum, skipped" => result.bad_copies
    }
    rows["Thumbnails and previews deleted, made again when shown"] = result.representations if confirm
    rows["Errors"] = result.failed
    width = rows.keys.map(&:length).max
    rows.each { |label, count| puts "  #{label.ljust(width)}  #{count}" }
    result.errors.each { |error| puts "  #{error}" }
    abort "#{result.failed} file(s) could not be checked or uploaded." if result.failed.positive?
  end

  desc "Show the file copies in FILE_COPY_DIR: last run, files copied, trash and free disk space"
  task file_copy_status: :environment do
    status = Backups::FileCopyStatus.current
    unless status.configured?
      puts "FILE_COPY_DIR is not set, so file copies are off."
      next
    end

    store = status.store
    size = ->(bytes) { ActiveSupport::NumberHelper.number_to_human_size(bytes) }
    time = ->(at) { at ? at.strftime("%b %-d, %Y %-l:%M %p %Z") : "never" }
    puts "File copies in #{store.root}"
    if status.folder_problem
      puts "  Folder problem: #{status.folder_problem.to_s.humanize(capitalize: false)}. " \
        "On the VM run: #{Backups::FileCopyStore::SETUP_COMMAND}"
      next if status.folder_problem == :missing
    end

    inventory = status.inventory
    space = store.disk_space
    rows = {
      "Last run" => status.last_run ? "#{time.(status.last_run_at)} (#{status.last_run["outcome"]})" : "never",
      "Last complete copy" => time.(status.last_success_at),
      "Files to keep" => "#{inventory.kept} (#{size.(inventory.kept_bytes)})",
      "Copied" => "#{inventory.copied} (#{size.(inventory.copied_bytes)})",
      "Not copied yet" => inventory.kept - inventory.copied,
      "In the trash" => "#{inventory.trash_files} (#{size.(inventory.trash_bytes)})" \
        "#{", oldest from #{inventory.trash_days.first.iso8601}" if inventory.trash_days.any?}",
      "Free space" => "#{size.(space.free_bytes)} of #{size.(space.total_bytes)} (copying stops under #{size.(space.reserve_bytes)})"
    }
    width = rows.keys.map(&:length).max
    rows.each { |label, value| puts "  #{label.ljust(width)}  #{value}" }
    Array(status.last_run&.dig("errors")).each { |error| puts "  Last run error: #{error}" }
  end
end
