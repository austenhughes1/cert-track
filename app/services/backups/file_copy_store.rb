require "open3"

module Backups
  # The folder on the VM's own disk that holds the nightly copy of the certificate files
  # (FILE_COPY_DIR; production mounts /var/lib/certtrack/file-copies there, config/deploy.yml):
  #
  #   ab/cd/<key>                   the copy of blob <key>, laid out like an Active Storage Disk service
  #   trash/YYYY-MM-DD/ab/cd/<key>  a copy whose blob was gone on that day; deleted TRASH_DAYS later
  #   incoming/                     downloads in progress, moved into place once their checksum matches
  #   status.json                   the last run (Backups::FileCopy), read by the dashboard banner
  #   copy.lock                     held while a run is in progress
  #
  # Copies are readable by the app's own user only (files 0600, folders 0700): they hold personal data.
  class FileCopyStore
    class DirectoryError < StandardError; end

    TRASH_DIR = "trash".freeze
    INCOMING_DIR = "incoming".freeze
    STATUS_FILE = "status.json".freeze
    LOCK_FILE = "copy.lock".freeze
    TRASH_DAYS = 30
    # Copying stops before free space drops under the larger of these: Postgres shares the disk.
    MIN_FREE_BYTES = 5.gigabytes
    MIN_FREE_SHARE = 0.10
    HOST_DIR = "/var/lib/certtrack/file-copies".freeze
    SETUP_COMMAND = "sudo mkdir -p #{HOST_DIR} && sudo chown 1000:1000 #{HOST_DIR}".freeze
    SETUP_STEP = %(docs/DEPLOY.md, "File copies").freeze
    # Live copies sit two folders deep (ab/cd/<key>); trash/ and incoming/ never match.
    COPY_GLOB = "??/??/**/*".freeze
    DAY_NAME = /\A\d{4}-\d{2}-\d{2}\z/

    DiskSpace = Data.define(:total_bytes, :free_bytes) do
      def reserve_bytes = [ MIN_FREE_BYTES, (total_bytes * MIN_FREE_SHARE).ceil ].max

      # Whether bytes more can be written and still leave the reserve free.
      def room_for?(bytes) = free_bytes - bytes >= reserve_bytes

      def low? = !room_for?(0)
    end

    # Free space on the filesystem holding root, from POSIX df. Tests swap in a lambda.
    class_attribute :disk_space_reader, default: ->(root) { read_disk_space(root) }

    # The store at FILE_COPY_DIR, or nil when it is unset (development and test): copies are off.
    def self.configured
      root = ENV["FILE_COPY_DIR"].presence
      new(root) if root
    end

    def self.read_disk_space(root)
      output, errors, status = Open3.capture3("df", "-P", "-k", "--", root.to_s)
      # "Filesystem 1024-blocks Used Available Capacity Mounted-on": match the numbers, since the
      # device and mount names may hold spaces.
      match = output.lines.drop(1).join.match(/\s(\d+)\s+\d+\s+(\d+)\s+\d+%\s/) if status.success?
      raise DirectoryError, "Could not read free space for #{root}: #{errors.strip.presence || output.strip}" unless match

      DiskSpace.new(total_bytes: match[1].to_i * 1024, free_bytes: match[2].to_i * 1024)
    end

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root.to_s)
      @layouts = {}
    end

    # :missing, :not_writable, or nil when the folder is ready.
    def problem
      if !File.directory?(root) then :missing
      elsif !File.writable?(root) || !File.executable?(root) then :not_writable
      end
    end

    # Raises DirectoryError, naming the setup step, unless the folder is ready.
    def check!
      case problem
      when :missing
        raise DirectoryError, "The file copy folder #{root} does not exist (in production: the Kamal volume " \
          "isn't mounted). On the VM run: #{SETUP_COMMAND}, then bin/kamal deploy (#{SETUP_STEP})."
      when :not_writable
        raise DirectoryError, "The file copy folder #{root} can't be written by uid #{Process.euid} " \
          "(Docker creates a missing host folder as root). On the VM run: #{SETUP_COMMAND} (#{SETUP_STEP})."
      end
    end

    def disk_space
      disk_space_reader.call(root)
    end

    # Runs the block while holding the store's lock, so two runs never share incoming/.
    def with_lock
      File.open(File.join(root, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def path_for(key)
      layout(root).path_for(key)
    end

    def trash_path_for(key, day)
      layout(trash_dir(day)).path_for(key)
    end

    # Whether path holds a file of blob's size. Sizes are compared, not checksums: every copy
    # was checked against its blob's MD5 before it was moved into place.
    def matches?(path, blob)
      File.file?(path) && File.size(path) == blob.byte_size
    end

    def copied?(blob)
      matches?(path_for(blob.key), blob)
    end

    # The newest copy of blob in the trash with blob's size, or nil.
    def trashed_copy_path(blob)
      trash_days.reverse_each.map { |day| trash_path_for(blob.key, day) }.find { |path| matches?(path, blob) }
    end

    # Blob's live copy, else its newest copy in the trash, else nil.
    def copy_path_for(blob)
      path = path_for(blob.key)
      matches?(path, blob) ? path : trashed_copy_path(blob)
    end

    # Keys of the live copies.
    def keys
      Dir.glob(COPY_GLOB, base: root).filter_map { |relative| relative[6..] if File.file?(File.join(root, relative)) }
    end

    # Yields a new, empty file in incoming/; once the block returns, moves it into place as the
    # copy of key and returns its path. A block that raises leaves no file behind. The file is in
    # binary mode: Rails sets Encoding.default_internal, so a text-mode file would try to convert
    # each chunk to UTF-8 and fail on the first byte that isn't valid UTF-8.
    def receive(key)
      destination = path_for(key)
      incoming = File.join(root, INCOMING_DIR)
      FileUtils.mkdir_p(incoming, mode: 0o700)
      temp = File.join(incoming, SecureRandom.hex(16))
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600, binmode: true) do |file|
        yield file
        file.fsync
      end
      move(temp, destination)
      destination
    ensure
      FileUtils.rm_f(temp) if temp
    end

    # Downloads a crashed run left behind.
    def clear_incoming
      FileUtils.rm_rf(File.join(root, INCOMING_DIR))
    end

    def move_to_trash(key, day:)
      move(path_for(key), trash_path_for(key, day))
    end

    # Moves blob's newest trashed copy back into place (its row is back, e.g. after a database
    # restore). Returns false when the trash has no copy of the right size.
    def untrash(blob)
      source = trashed_copy_path(blob)
      return false unless source

      move(source, path_for(blob.key))
      true
    end

    # Keys of the copies in the trash, from every day.
    def trashed_keys
      trash_days.flat_map { |day| files_in(trash_dir(day)).map { |path| File.basename(path) } }.uniq
    end

    # Dates of the trash folders, oldest first.
    def trash_days
      base = File.join(root, TRASH_DIR)
      return [] unless File.directory?(base)

      Dir.children(base).filter_map do |name|
        Date.iso8601(name) if name.match?(DAY_NAME)
      rescue Date::Error
        nil
      end.sort
    end

    # Deletes the trash folders from TRASH_DAYS or more before today. Returns the files deleted.
    def expire_trash(today: Date.current)
      trash_days.select { |day| day <= today - TRASH_DAYS }.sum do |day|
        files = files_in(trash_dir(day)).size
        FileUtils.rm_rf(trash_dir(day))
        files
      end
    end

    # [files, bytes] in the trash.
    def trash_usage
      files = trash_days.flat_map { |day| files_in(trash_dir(day)) }
      [ files.size, files.sum { |path| File.size(path) } ]
    end

    # The last run as written by #write_status (string keys), or nil.
    def read_status
      JSON.parse(File.read(File.join(root, STATUS_FILE)))
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      nil
    end

    def write_status(status)
      path = File.join(root, STATUS_FILE)
      temp = "#{path}.#{SecureRandom.hex(4)}.tmp"
      File.write(temp, JSON.pretty_generate(status), perm: 0o600)
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if temp
    end

    private
      # DiskService#path_for lays keys out as ab/cd/<key> and refuses keys that would leave its root.
      def layout(dir)
        @layouts[dir] ||= ActiveStorage::Service::DiskService.new(root: dir)
      end

      def trash_dir(day)
        File.join(root, TRASH_DIR, day.iso8601)
      end

      def files_in(dir)
        Dir.glob(COPY_GLOB, base: dir).map { |relative| File.join(dir, relative) }.select { |path| File.file?(path) }
      end

      def move(source, destination)
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        File.rename(source, destination)
      end
  end
end
