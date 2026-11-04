class ApplicationMailer < ActionMailer::Base
  # Development and test, where neither MAIL_FROM nor SMTP_USERNAME is set.
  PLACEHOLDER_FROM = "CertTrack <certtrack@example.com>".freeze

  # Production sends through the office's Google Workspace account (config/environments/production.rb).
  # Gmail rewrites any From that isn't that account (SMTP_USERNAME) or one of its "Send mail as"
  # aliases, so MAIL_FROM must be one of those. Read per email, not at boot.
  default from: -> { ApplicationMailer.from_address }
  layout "mailer"

  def self.from_address
    ENV["MAIL_FROM"].presence ||
      ENV["SMTP_USERNAME"].presence&.then { |account| email_address_with_name(account, "CertTrack") } ||
      PLACEHOLDER_FROM
  end
end
