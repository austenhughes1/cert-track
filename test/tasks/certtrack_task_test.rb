require "test_helper"
require "rake"

class CerttrackTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("certtrack:create_admin")
    Rake::Task["certtrack:create_admin"].reenable
  end

  test "creates an admin with the given password" do
    out = run_task({ "EMAIL" => "Boss@Example.com", "NAME" => "Bo Boss", "PASSWORD" => "correct horse battery" })

    user = User.find_by!(email_address: "boss@example.com")
    assert user.admin?
    assert_equal "Bo Boss", user.name
    assert user.authenticate("correct horse battery")
    assert_match "Created admin boss@example.com.", out
    assert_no_match "correct horse battery", out
  end

  test "generates and prints a password once when there is no terminal" do
    out = run_task({ "EMAIL" => "ops@example.com" }, stdin: FakeStdin.new(tty: false))

    password = out[/Generated password \(shown once, store it now\): (\S+)/, 1]
    assert password, "expected the generated password in: #{out}"
    assert_operator password.length, :>=, 20
    assert_equal 1, out.scan(password).size
    assert User.find_by!(email_address: "ops@example.com").authenticate(password)
  end

  test "prompts for the password without echo on a terminal" do
    stdin = FakeStdin.new(tty: true, passwords: [ "typed password", "typed password" ])
    out = run_task({ "EMAIL" => "tty@example.com" }, stdin: stdin)

    assert_equal [ "Password (8+ characters): ", "Repeat password: " ], stdin.prompts
    assert User.find_by!(email_address: "tty@example.com").authenticate("typed password")
    assert_no_match "typed password", out
  end

  test "prompts for the email on a terminal when EMAIL is missing" do
    stdin = FakeStdin.new(tty: true, lines: [ "asked@example.com\n" ], passwords: [ "typed password" ] * 2)
    run_task({}, stdin: stdin)

    assert User.find_by!(email_address: "asked@example.com").admin?
  end

  test "aborts when typed passwords differ" do
    stdin = FakeStdin.new(tty: true, passwords: [ "typed password", "different one" ])

    assert_no_difference -> { User.count } do
      assert_raises(SystemExit) { run_task({ "EMAIL" => "tty@example.com" }, stdin: stdin) }
    end
  end

  test "aborts without EMAIL when there is no terminal" do
    assert_raises(SystemExit) { run_task({}, stdin: FakeStdin.new(tty: false)) }
  end

  test "aborts with the validation errors for a bad password" do
    assert_no_difference -> { User.count } do
      assert_raises(SystemExit) { run_task({ "EMAIL" => "weak@example.com", "PASSWORD" => "short" }) }
    end
  end

  test "promotes an existing user and keeps their password" do
    viewer = users(:viewer)
    digest = viewer.password_digest

    out = run_task({ "EMAIL" => "viewer@example.com" }, stdin: FakeStdin.new(tty: true))

    assert viewer.reload.admin?
    assert_equal digest, viewer.password_digest
    assert_match "Promoted viewer to admin viewer@example.com.", out
    assert_no_match "Generated password", out
  end

  test "changes an existing user's password only when PASSWORD is given" do
    run_task({ "EMAIL" => "admin@example.com", "PASSWORD" => "rotated password" })
    assert users(:admin).reload.authenticate("rotated password")
  end

  test "is idempotent" do
    env = { "EMAIL" => "twice@example.com", "PASSWORD" => "the password" }

    assert_difference -> { User.count }, 1 do
      run_task(env)
      Rake::Task["certtrack:create_admin"].reenable
      assert_match "Updated admin twice@example.com.", run_task(env)
    end
  end

  private
    # Stands in for $stdin: tty? plus io/console's getpass.
    class FakeStdin
      attr_reader :prompts

      def initialize(tty:, passwords: [], lines: [])
        @tty, @passwords, @lines, @prompts = tty, passwords.dup, lines.dup, []
      end

      def tty? = @tty
      def gets = @lines.shift

      def getpass(prompt)
        @prompts << prompt
        @passwords.shift
      end
    end

    def run_task(env, stdin: FakeStdin.new(tty: false))
      keys = %w[EMAIL NAME PASSWORD]
      saved = ENV.to_h.slice(*keys)
      keys.each { |key| ENV.delete(key) }
      env.each { |key, value| ENV[key] = value }
      original_stdin, $stdin = $stdin, stdin

      out, _err = capture_io { Rake::Task["certtrack:create_admin"].invoke }
      out
    ensure
      $stdin = original_stdin
      keys.each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
    end
end
