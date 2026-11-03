module Backups
  # Streams a plain-SQL pg_dump of one database into any object that responds to #write.
  #
  # --clean --if-exists lets the dump be replayed by hand over a copy of the same schema.
  # Backups::Restore doesn't rely on it: it always loads into an empty database, since
  # --clean can't drop objects (or foreign keys) from a newer schema.
  class Dump
    class Error < StandardError; end

    CHUNK_SIZE = 256 * 1024
    OPTIONS = %w[--format=plain --no-owner --no-privileges --clean --if-exists].freeze

    def initialize(connection: PgConnection.primary)
      @connection = connection
    end

    def write_to(io)
      @connection.stream(argv) do |stdin, stdout|
        stdin.close
        while (chunk = stdout.read(CHUNK_SIZE))
          io.write(chunk)
        end
      end
      io
    rescue PgConnection::CommandError => error
      raise Error, error.message
    end

    def argv
      [ "pg_dump", *OPTIONS, *@connection.connection_args, "--dbname", @connection.database ]
    end
  end
end
