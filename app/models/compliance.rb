# Compliance status of one required certificate type for one person.
# "today" is Denver's date (config.time_zone). Compliance::ProjectReport builds on this.
module Compliance
  STATUSES = %w[missing expired expiring lapses_on_project valid].freeze
  SEVERITY = %w[expired missing expiring lapses_on_project valid].freeze # most severe first
  EXPIRING_WINDOW = 30 # days

  LABELS = {
    "missing" => "Missing",
    "expired" => "Expired",
    "expiring" => "Expiring",
    "lapses_on_project" => "Lapses on project",
    "valid" => "Valid"
  }.freeze

  module_function

  # certificate: the current Certificate for the person and type, or nil.
  def status_for(certificate, today: Date.current, project_ends_on: nil)
    return "missing" if certificate.nil?

    status_for_expiry(certificate.expires_on, today: today, project_ends_on: project_ends_on)
  end

  # Same rule for callers that only selected the expires_on column. nil = never expires.
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
