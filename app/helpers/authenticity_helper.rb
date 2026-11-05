# The authenticity panel (shared/_authenticity_panel) and the verification list (docs/PLAN.md,
# Phase 3b): status badges, who checked and when, and the links a person opens to check.
module AuthenticityHelper
  BADGE_BASE = "inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium".freeze

  # Full class strings so Tailwind's scanner picks them up. Flagged red, verified green,
  # needs a check amber, can't verify and not checked grey.
  BADGE_CLASSES = {
    "unchecked" => "bg-gray-100 text-gray-600",
    "needs_check" => "bg-amber-100 text-amber-800 ring-1 ring-inset ring-amber-600/30",
    "verified" => "bg-green-100 text-green-800 ring-1 ring-inset ring-green-600/20",
    "cannot_verify" => "bg-gray-200 text-gray-700",
    "not_found" => "bg-red-600 text-white ring-1 ring-inset ring-red-700",
    "mismatch" => "bg-red-600 text-white ring-1 ring-inset ring-red-700",
    "suspicious" => "bg-red-600 text-white ring-1 ring-inset ring-red-700"
  }.freeze
  # A person's not_found or mismatch (confirmed fake): darker, like ComplianceHelper's "fake".
  FAKE_BADGE_CLASSES = "bg-red-800 text-white ring-1 ring-inset ring-red-900".freeze
  FAKE_LABEL = "Confirmed fake".freeze

  # The panel's result buttons, in order, for Authenticity::PERSON_STATUSES.
  RESULT_BUTTONS = {
    "verified" => [ "Verified", "border-green-300 text-green-800 hover:bg-green-50" ],
    "not_found" => [ "Not found", "border-red-300 text-red-700 hover:bg-red-50" ],
    "mismatch" => [ "Doesn't match", "border-red-300 text-red-700 hover:bg-red-50" ],
    "cannot_verify" => [ "Can't be verified", "border-gray-300 text-gray-700 hover:bg-gray-50" ]
  }.freeze

  # What the panel works with for a Certificate or an ImportItem: its issuer, verification code
  # and link, and where its result buttons and "Check again" post.
  Subject = Data.define(:issuer, :code, :url, :update_path, :recheck_path)

  # A coloured pill for a record's authenticity_status (or a bare status). A record a person
  # confirmed fake reads "Confirmed fake" (titled with what they found); one only flagged for
  # review keeps its status label, titled "Flagged for review: ...".
  def authenticity_badge(record_or_status)
    record = record_or_status if record_or_status.respond_to?(:authenticity_status)
    status = record ? record.authenticity_status : record_or_status.to_s
    label = Authenticity::LABELS.fetch(status) { status.humanize }

    if record&.authenticity_confirmed_fake?
      tag.span(FAKE_LABEL, class: "#{BADGE_BASE} #{FAKE_BADGE_CLASSES}", title: "#{FAKE_LABEL}: #{label}",
        data: { authenticity: status, fake: "true" })
    else
      title = "Flagged for review: #{label}" if record&.authenticity_flagged_for_review?
      tag.span(label, class: "#{BADGE_BASE} #{BADGE_CLASSES.fetch(status, BADGE_CLASSES["unchecked"])}", title: title,
        data: { authenticity: status })
    end
  end

  # The confirm dialog for a result button that marks the record as fake (Not found, Doesn't
  # match), or nil for the others.
  def authenticity_result_confirm(record, status)
    return unless Authenticity::FAKE_STATUSES.include?(status.to_s)

    if record.is_a?(ImportItem)
      "Record this as fake? Once accepted, it will count as not valid and be left out of packets."
    else
      "Record this certificate as fake? It will count as not valid and be left out of packets."
    end
  end

  # What a confirmed fake record means, for the panel.
  def authenticity_fake_sentence(record)
    if record.is_a?(ImportItem)
      "Confirmed fake: a person checked it with the issuer. Once accepted, it counts as not valid in compliance and is left out of packets."
    else
      "Confirmed fake: a person checked it with the issuer. It counts as not valid in compliance and is left out of packets."
    end
  end

  # What a record only flagged for review means, for the panel. An import item counts nowhere yet,
  # so its sentence is about once it is accepted.
  def authenticity_flagged_sentence(record)
    if record.is_a?(ImportItem)
      "Flagged for review. Once accepted, it counts by its dates and goes in packets until someone checks it with the issuer " \
        "and records the result."
    else
      "Flagged for review. It still counts by its dates and goes in packets until someone checks it with the issuer and records the result."
    end
  end

  def authenticity_subject(record)
    case record
    when Certificate
      Subject.new(issuer: record.certificate_issuer, code: record.verification_code, url: record.verification_url,
        update_path: crew_member_certificate_authenticity_path(record.crew_member_id, record),
        recheck_path: recheck_crew_member_certificate_authenticity_path(record.crew_member_id, record))
    when ImportItem
      Subject.new(issuer: record.matched_certificate_issuer, code: record.proposed_verification_code,
        url: record.proposed_verification_url,
        update_path: import_review_authenticity_path(record), recheck_path: recheck_import_review_authenticity_path(record))
    else
      raise ArgumentError, "no authenticity panel for #{record.class.name}"
    end
  end

  # "Checked by Ada Admin on Nov 4, 2026 at 5:05 PM MST", "Checked automatically on ...", or
  # "Not checked yet".
  def authenticity_checked_sentence(record)
    at = record.authenticity_checked_at
    return "Not checked yet" if at.nil?

    who = if record.authenticity_set_by_person?
      "by #{record.authenticity_checked_by&.display_name || "a former user"}"
    else
      "automatically"
    end
    at = at.in_time_zone
    safe_join([ "Checked #{who} on ", tag.time(at.strftime("%b %-d, %Y at %-l:%M %p %Z"), datetime: at.iso8601) ])
  end

  # The URL when it is an https:// link with a host, else nil: only those are ever rendered as links
  # (a stored link is normalized to https, but an issuer's lookup page is typed by an admin).
  def authenticity_safe_url(url)
    uri = URI.parse(url.to_s.strip)
    uri.to_s if uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  # Why a record's verification link can't be trusted (it imitates an issuer's site, or is
  # disguised: Verification::Lookalike#suspicion), or nil. The panel then doesn't link it, even
  # before a check has flagged the record.
  def authenticity_link_suspicion(url)
    Verification::Lookalike.for_issuers.suspicion(url) if url.present?
  end

  # "This link points to redcross-verify.com, which looks like redcross.org but isn't, so it isn't linked here."
  def authenticity_suspicion_sentence(suspicion)
    "This link #{Verification::Run.suspicion_words(suspicion)}, so it isn't linked here."
  end

  # An import item's issuer that is only a suggestion from the printed name, not yet saved by a
  # reviewer: Verification::Run doesn't trust it with an automatic check.
  def authenticity_issuer_unconfirmed?(record)
    record.is_a?(ImportItem) && record.matched_certificate_issuer.present? && !record.issuer_matched?
  end

  # "redcross.org", for showing where a link goes.
  def authenticity_link_host(url)
    CertificateIssuer.host_of(url)
  end
end
