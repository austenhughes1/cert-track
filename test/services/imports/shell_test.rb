require "test_helper"

class Imports::ShellTest < ActiveSupport::TestCase
  test "returns stdout of an argv command, with no shell interpretation" do
    assert_equal "a b; echo injected\n", Imports::Shell.run("echo", "a b; echo injected")
  end

  test "raises Failed with the exit status and stderr" do
    error = assert_raises(Imports::Shell::Failed) do
      Imports::Shell.run(RbConfig.ruby, "-e", "warn 'bad page'; exit 3")
    end

    assert_equal 3, error.exit_status
    assert_equal "bad page", error.stderr
    assert_match(/exit 3.*bad page/, error.message)
  end

  test "kills a tool that runs past its timeout" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Imports::Shell::TimedOut) { Imports::Shell.run("sleep", "10", timeout: 0.3) }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_match "sleep did not finish within 0.3 seconds", error.message
  end

  test "a missing tool says which package to install" do
    error = assert_raises(Imports::Shell::CommandNotFound) { Imports::Shell.run("certtrack-missing-tool") }
    assert_match "certtrack-missing-tool could not be run", error.message

    with_path("") do
      error = assert_raises(Imports::Shell::CommandNotFound) { Imports::Shell.run("tesseract", "--version") }
      assert_match "Install tesseract-ocr and tesseract-ocr-eng", error.message

      error = assert_raises(Imports::Shell::CommandNotFound) { Imports::Shell.run("pdfimages", "-list", "scan.pdf") }
      assert_match "Install poppler-utils", error.message, "Certificates::PdfShrinker's tool names its package too"
    end
  end

  test "drains large output without blocking" do
    output = Imports::Shell.run(RbConfig.ruby, "-e", "STDOUT.write('x' * 1_000_000); STDERR.write('y' * 500_000)")

    assert_equal 1_000_000, output.bytesize
  end

  test "caps tesseract at one thread" do
    assert_equal "1\n", Imports::Shell.run(RbConfig.ruby, "-e", "puts ENV['OMP_THREAD_LIMIT']")
  end

  private
    def with_path(path)
      original = ENV["PATH"]
      ENV["PATH"] = path
      yield
    ensure
      ENV["PATH"] = original
    end
end
