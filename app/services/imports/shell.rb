require "open3"

module Imports
  # Runs the local extraction tools (poppler, tesseract) safely: argv arrays only, never a
  # shell string; a hard timeout that kills the tool's whole process group; and errors that
  # say what went wrong and how to fix it.
  #
  #   Imports::Shell.run("pdfinfo", path)                 # => stdout (String)
  #   Imports::Shell.run("tesseract", png, "stdout", timeout: 90)
  module Shell
    class Error < StandardError; end

    # The executable is not installed or not on PATH.
    class CommandNotFound < Error; end

    # The tool ran longer than its timeout and was killed. Usually transient (a busy box).
    class TimedOut < Error; end

    # The tool exited non-zero.
    class Failed < Error
      attr_reader :command, :exit_status, :stderr

      def initialize(command, exit_status, stderr)
        @command = command
        @exit_status = exit_status
        @stderr = stderr
        detail = stderr.presence || "no error output"
        super("#{command} failed (exit #{exit_status.inspect}): #{detail}")
      end
    end

    DEFAULT_TIMEOUT = 60 # seconds per tool call
    STDERR_LIMIT = 500
    # Tesseract's OpenMP threads fight each other when several jobs OCR at once on a small VM.
    CHILD_ENV = { "OMP_THREAD_LIMIT" => "1" }.freeze
    # Also used by Certificates::PdfShrinker (pdfimages).
    PACKAGES = {
      "pdfimages" => "poppler-utils", "pdfinfo" => "poppler-utils", "pdftotext" => "poppler-utils",
      "pdftoppm" => "poppler-utils", "tesseract" => "tesseract-ocr and tesseract-ocr-eng"
    }.freeze

    class << self
      # Runs argv and returns its stdout. Raises CommandNotFound, TimedOut or Failed.
      def run(*argv, timeout: DEFAULT_TIMEOUT)
        argv = argv.flatten.map(&:to_s)
        raise ArgumentError, "no command given" if argv.empty?

        Open3.popen3(CHILD_ENV, *argv, pgroup: true) do |stdin, stdout, stderr, waiter|
          stdin.close
          output = reader(stdout)
          errors = reader(stderr)

          unless waiter.join(timeout)
            kill(waiter.pid)
            waiter.join
            raise TimedOut, "#{argv.first} did not finish within #{timeout} seconds and was stopped"
          end

          status = waiter.value
          raise Failed.new(argv.first, status.exitstatus || status.termsig, clean(errors.value)) unless status.success?

          output.value
        end
      rescue Errno::ENOENT, Errno::EACCES => error
        raise CommandNotFound, not_found_message(argv.first, error)
      end

      private
        # Drains a pipe in the background so the tool never blocks on a full buffer.
        def reader(io)
          Thread.new do
            Thread.current.report_on_exception = false
            io.read
          end
        end

        # Kills the tool and anything it started (it runs in its own process group).
        def kill(pid)
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH, Errno::EPERM
          # Already gone.
        end

        def clean(text)
          text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("").squish.truncate(STDERR_LIMIT)
        end

        def not_found_message(command, error)
          package = PACKAGES.fetch(File.basename(command.to_s), command)
          "#{command} could not be run (#{error.class.name.demodulize}). Install #{package} on this machine " \
            "and make sure it is on PATH."
        end
    end
  end
end
