require "open3"

module Backups
  # Connection settings for the PostgreSQL command-line tools (pg_dump, psql), taken
  # from an Active Record configuration hash. The password travels only in the child
  # process's PGPASSWORD, never on the command line or in logs.
  class PgConnection
    class CommandError < StandardError; end

    STDERR_LIMIT = 2_000

    def self.primary
      new(ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    attr_reader :database

    def initialize(config)
      @config = config.to_h.symbolize_keys
      @database = @config[:database].to_s
      raise ArgumentError, "database config has no database name" if @database.empty?
    end

    def with_database(name)
      self.class.new(@config.merge(database: name))
    end

    # Flags shared by pg_dump and psql; the database itself goes in --dbname.
    def connection_args
      { "--host" => @config[:host], "--port" => @config[:port], "--username" => @config[:username] }
        .compact_blank
        .flat_map { |flag, value| [ flag, value.to_s ] }
    end

    def env
      { "PGPASSWORD" => @config[:password], "PGSSLMODE" => @config[:sslmode] }
        .compact_blank
        .transform_values(&:to_s)
    end

    # Runs a short SQL script through psql (stdin, so psql :'var' / :"var" quoting works)
    # and returns its stdout.
    def psql(sql, database: self.database, variables: {})
      stdout, stderr, status = Open3.capture3(env, *psql_argv(database, variables, "--tuples-only", "--no-align"),
        stdin_data: sql)
      raise CommandError, "psql failed (#{status}): #{stderr.strip.truncate(STDERR_LIMIT)}" unless status.success?

      stdout
    end

    # Runs a long-lived command (argv array, never a shell string) with this connection's
    # environment, yielding its stdin and stdout for streaming. stderr is drained in the
    # background so the child never blocks on it. Raises CommandError on a non-zero exit.
    def stream(argv)
      Open3.popen3(env, *argv) do |stdin, stdout, stderr, wait_thread|
        errors = Thread.new { Thread.current.report_on_exception = false; stderr.read }
        begin
          yield stdin, stdout
          stdin.close unless stdin.closed?
        rescue Errno::EPIPE
          # The child stopped reading early; its exit status and stderr say why.
        end

        status = wait_thread.value
        message = errors.value.to_s.strip.truncate(STDERR_LIMIT)
        raise CommandError, "#{argv.first} failed (#{status}): #{message}" unless status.success?
      end
    end

    def psql_argv(database, variables = {}, *flags)
      [
        "psql", "--no-psqlrc", "--quiet", "--set", "ON_ERROR_STOP=1",
        *variables.flat_map { |name, value| [ "--set", "#{name}=#{value}" ] },
        *flags, *connection_args, "--dbname", database
      ]
    end

    def inspect
      "#<#{self.class.name} database=#{database.inspect}>"
    end
  end
end
