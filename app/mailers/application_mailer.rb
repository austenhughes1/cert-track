class ApplicationMailer < ActionMailer::Base
  # Must be an address on the Resend-verified domain (notify.abaventures.net).
  default from: ENV.fetch("MAIL_FROM", "CertTrack <certtrack@notify.abaventures.net>")
  layout "mailer"
end
