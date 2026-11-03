require "zlib"

module Backups
  # Downloads a backup (the newest unless key: is given), authenticates and decrypts it
  # to a temp file, replays it with psql into a new, empty staging database, and then
  # replaces the target database with it. Refuses the app's own databases unless force: true.
  class Restore
    class Error < StandardError; end

    DEFAULT_TARGET = "cert_track_restore_check".freeze
    SANITY_TABLES = %w[users crew_members certificates projects].freeze
    STAGING_SUFFIX = "_restoring".freeze
    # At most 53 characters, so the staging name still fits Postgres's 63.
    DATABASE_NAME = /\A[A-Za-z0-9_][A-Za-z0-9_-]{0,#{62 - STAGING_SUFFIX.length}}\z/
    # Databases are dropped, created and renamed from here, never from the target itself.
    MAINTENANCE_DATABASE = "postgres".freeze

    Result = Data.define(:key, :database, :row_counts)

    # The database a restore loads into before it replaces target.
    def self.staging_database_for(target)
      "#{target}#{STAGING_SUFFIX}"
    end

    def initialize(target_database: DEFAULT_TARGET, force: false, key: nil, storage: nil, encryptor: nil,
      connection: PgConnection.primary)
      @target = target_database.to_s
      @force = force
      @key = key
      @storage = storage
      @encryptor = encryptor
      @connection = connection
    end

    def call
      check_target!
      key = @key || storage.latest_key || raise(Error, "No backups found in #{storage.bucket}/#{Storage::PREFIX}")

      Dir.mktmpdir("cert_track-restore") do |dir|
        encrypted = File.join(dir, "backup.sql.gz.enc")
        compressed = File.join(dir, "backup.sql.gz")
        storage.download(key, encrypted)
        # Authenticates the whole file before a single statement reaches psql.
        encryptor.decrypt_file(encrypted, compressed)
        restore_into_fresh_database(compressed)
      end

      Result.new(key:, database: @target, row_counts:)
    rescue Encryptor::Error, PgConnection::CommandError => error
      raise Error, error.message
    end

    private
      def storage = @storage ||= Storage.new
      def encryptor = @encryptor ||= Encryptor.new

      def check_target!
        unless DATABASE_NAME.match?(@target)
          raise Error, "#{@target.inspect} is not a plain database name (letters, digits, _ and -, at most 53 characters)"
        end
        return if @force || app_databases.exclude?(@target)

        raise Error, "Refusing to restore over #{@target}, one of this app's own databases. Set FORCE=1 to overwrite it."
      end

      def app_databases
        configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, include_hidden: true)
        [ @connection.database, *configs.map(&:database) ].compact.uniq
      end

      def maintenance = @maintenance ||= @connection.with_database(MAINTENANCE_DATABASE)

      # The dump's --clean only drops objects the dump knows about. Replaying it over a
      # database with a newer schema (the rebuild runbook restores over what db:prepare
      # just loaded) fails on foreign keys into dumped tables, or leaves newer tables
      # behind for their migrations to trip over. So the dump always goes into an empty
      # database, which only replaces the target once it has loaded: a failed restore
      # leaves the target as it was.
      def restore_into_fresh_database(compressed)
        staging = self.class.staging_database_for(@target)
        # template0 is guaranteed empty; template1 may carry local additions.
        maintenance.psql(<<~'SQL', variables: { staging: })
          DROP DATABASE IF EXISTS :"staging" WITH (FORCE);
          CREATE DATABASE :"staging" TEMPLATE template0 ENCODING 'UTF8';
        SQL

        begin
          load_sql(compressed, staging)
        rescue StandardError
          drop_quietly(staging)
          raise
        end

        replace_target_with(staging)
      end

      # Streams the gunzipped SQL into psql inside one transaction.
      def load_sql(compressed, database)
        @connection.stream(@connection.psql_argv(database, {}, "--single-transaction")) do |stdin, stdout|
          Thread.new { Thread.current.report_on_exception = false; IO.copy_stream(stdout, File::NULL) }
          Zlib::GzipReader.open(compressed) { |gzip| IO.copy_stream(gzip, stdin) }
        end
      end

      # DROP DATABASE can't share a transaction with the rename, so name the staging
      # database in the error: if the rename fails after the drop, the data is there.
      def replace_target_with(staging)
        maintenance.psql(<<~'SQL', variables: { target: @target, staging: })
          DROP DATABASE IF EXISTS :"target" WITH (FORCE);
          ALTER DATABASE :"staging" RENAME TO :"target";
        SQL
      rescue PgConnection::CommandError => error
        raise Error, "#{error.message} (the restored data is in #{staging})"
      end

      # Best effort: the next restore drops a leftover staging database anyway.
      def drop_quietly(database)
        maintenance.psql(%(DROP DATABASE IF EXISTS :"database" WITH (FORCE);\n), variables: { database: })
      rescue PgConnection::CommandError
        nil
      end

      # Row counts for whichever SANITY_TABLES exist in the restored database.
      def row_counts
        output = @connection.psql(<<~'SQL', database: @target, variables: { tables: SANITY_TABLES.join(",") })
          SELECT format('SELECT %L, count(*) FROM public.%I', c.relname, c.relname)
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
            AND c.relname = ANY (string_to_array(:'tables', ','))
          \gexec
        SQL

        counts = output.lines.filter_map { |line| line.chomp.split("|", 2) if line.include?("|") }
          .to_h { |table, count| [ table, count.to_i ] }
        SANITY_TABLES.select { |table| counts.key?(table) }.index_with { |table| counts[table] }
      end
  end
end
