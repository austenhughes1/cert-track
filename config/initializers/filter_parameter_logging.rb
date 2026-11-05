# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :certificate_number, # PII (docs/PLAN.md); already partially matched by :certificate, listed explicitly
  # Phase 3b: a verification code is often the certificate number, and a QR link can carry the
  # holder's name and issue date (both encrypted at rest). Also matches proposed_verification_*.
  :verification_code, :verification_url,
  "authenticity.note" # what a person found when checking a certificate, typed freely
]
