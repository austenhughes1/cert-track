require "test_helper"

class ApplicationMailerTest < ActionMailer::TestCase
  MAIL_ENV = %w[MAIL_FROM SMTP_USERNAME].freeze

  setup do
    @saved_env = MAIL_ENV.index_with { |name| ENV[name] }
    MAIL_ENV.each { |name| ENV.delete(name) }
  end

  teardown do
    @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "mail comes from MAIL_FROM" do
    ENV["MAIL_FROM"] = "CertTrack <office@abaventures.net>"
    ENV["SMTP_USERNAME"] = "austen@abaventures.net"

    assert_equal "CertTrack <office@abaventures.net>", from_header(PasswordsMailer.reset(users(:admin)))
    assert_equal "CertTrack <office@abaventures.net>", from_header(UserMailer.invite(users(:viewer)))
  end

  test "without MAIL_FROM mail comes from the SMTP account, named CertTrack" do
    ENV["SMTP_USERNAME"] = "austen@abaventures.net"

    assert_equal "CertTrack <austen@abaventures.net>", from_header(PasswordsMailer.reset(users(:admin)))

    ENV["MAIL_FROM"] = " "
    assert_equal "CertTrack <austen@abaventures.net>", from_header(PasswordsMailer.reset(users(:admin))), "a blank MAIL_FROM is unset"
  end

  test "with neither set, as in development and test, mail comes from a placeholder" do
    assert_equal "CertTrack <certtrack@example.com>", from_header(PasswordsMailer.reset(users(:admin)))
  end

  private
    def from_header(mail)
      mail[:from].to_s
    end
end
