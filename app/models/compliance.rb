# Compliance status of one required certificate type for one person.
# "today" is Denver's date (config.time_zone). Compliance::ProjectReport builds on this.
# fake (Phase 3b): a person checked the current certificate with its issuer and recorded it as not
# found or not matching (Authenticity#authenticity_confirmed_fake?), so it counts as not valid,
# whatever its dates, and is left out of packets. Never omit a certificate unless it is verified
# fake (owner, Nov 4, 2026): one only flagged for review (an automatic check's not_found or
# mismatch, a QR code's details, a lookalike link) keeps the status its dates give it.
module Compliance
  STATUSES = %w[missing fake expired expiring lapses_on_project valid].freeze
  SEVERITY = %w[fake expired missing expiring lapses_on_project valid].freeze # most severe first
  EXPIRING_WINDOW = 30 # days

  LABELS = {
    "missing" => "Missing",
    "fake" => "Confirmed fake",
    "expired" => "Expired",
    "expiring" => "Expiring",
    "lapses_on_project" => "Lapses on project",
    "valid" => "Valid"
  }.freeze

  module_function

  # certificate: the current Certificate for the person and type, or nil.
  def status_for(certificate, today: Date.current, project_ends_on: nil)
    return "missing" if certificate.nil?
    return "fake" if certificate.authenticity_confirmed_fake?

    status_for_expiry(certificate.expires_on, today: today, project_ends_on: project_ends_on)
  end

  # The date rule alone, for callers that only selected the expires_on column (a confirmed fake
  # certificate needs status_for). nil expires_on = never expires.
  def status_for_expiry(expires_on, today: Date.current, project_ends_on: nil)
    if expires_on.nil? then "valid"
    elsif expires_on < today then "expired"
    elsif expires_on <= today + EXPIRING_WINDOW then "expiring"
    elsif project_ends_on && expires_on < project_ends_on then "lapses_on_project"
    else "valid"
    end
  end

  # Most severe of the given statuses; nil when there are none.
  def worst(statuses)
    statuses.map(&:to_s).min_by { |status| SEVERITY.index(status) || SEVERITY.size }
  end

  def label(status)
    LABELS.fetch(status.to_s)
  end
end
