module ComplianceHelper
  NOT_REQUIRED = Compliance::ProjectReport::NOT_REQUIRED
  FAKE = "fake".freeze

  # Full class strings so Tailwind's scanner picks them up.
  BADGE_BASE = "inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium tabular-nums".freeze
  BADGE_CLASSES = {
    "valid" => "bg-green-100 text-green-800 ring-1 ring-inset ring-green-600/20",
    "expiring" => "bg-amber-100 text-amber-800 ring-1 ring-inset ring-amber-600/30",
    "lapses_on_project" => "bg-orange-100 text-orange-800 ring-1 ring-inset ring-orange-600/30",
    "expired" => "bg-red-600 text-white ring-1 ring-inset ring-red-700",
    FAKE => "bg-red-800 text-white ring-1 ring-inset ring-red-900",
    "missing" => "bg-white text-red-700 ring-1 ring-inset ring-red-500",
    NOT_REQUIRED => "text-gray-400"
  }.freeze
  # Smaller and upper-case so it doesn't read as a "Missing" badge.
  REVIEW_MARKER_CLASSES = "inline-flex items-center whitespace-nowrap rounded-full bg-white px-1.5 py-px text-[10px] " \
    "font-semibold uppercase tracking-wide text-red-700 ring-1 ring-inset ring-red-600".freeze

  STATUS_LABELS = Compliance::LABELS.merge(NOT_REQUIRED => "Not required").freeze

  # A coloured pill for a ProjectReport::Cell or a bare status. Shows the expiry date
  # when there is one, otherwise the status label; not_required is a grey dash.
  # fake always reads "Confirmed fake", titled with why when the certificate is known
  # (the cell's, or certificate:, e.g. "Confirmed fake: Not found by issuer"). A known
  # certificate only flagged for review gets flagged_for_review_marker after the pill.
  def compliance_badge(cell_or_status, expires_on = nil, certificate: nil)
    status, expires_on = compliance_badge_parts(cell_or_status, expires_on)
    certificate ||= cell_or_status.certificate if cell_or_status.respond_to?(:certificate)
    label = status_label(status)
    classes = "#{BADGE_BASE} #{compliance_status_classes(status)}"

    badge = if status == NOT_REQUIRED
      tag.span("—", class: classes, title: label, data: { status: status })
    elsif status == FAKE
      reason = certificate.authenticity_label if certificate.respond_to?(:authenticity_flagged?) && certificate.authenticity_flagged?
      tag.span(label, class: classes, title: [ label, reason ].compact.join(": "), data: { status: status })
    elsif expires_on
      verb = status == "expired" ? "expired" : "expires"
      tag.span(class: classes, title: "#{label}: #{verb} #{format_date(expires_on)}", data: { status: status }) do
        safe_join([ tag.span("#{label}, ", class: "sr-only"), format_date(expires_on) ])
      end
    else
      title = status == "valid" && cell_or_status.respond_to?(:certificate) ? "#{label}: never expires" : label
      tag.span(label, class: classes, title: title, data: { status: status })
    end

    marker = flagged_for_review_marker(certificate)
    marker ? safe_join([ badge, marker ]) : badge
  end

  # A small red "Review" pill for a certificate an automatic check, a QR code's details or a
  # lookalike link flagged (Authenticity#authenticity_flagged_for_review?): it still counts by its
  # dates, so its compliance badge stays as it is and this goes beside it. nil for anything else.
  # Reads only the certificate's own authenticity columns, so a preloaded matrix stays one query.
  def flagged_for_review_marker(certificate)
    return unless certificate.respond_to?(:authenticity_flagged_for_review?) && certificate.authenticity_flagged_for_review?

    label = certificate.authenticity_label
    tag.span(class: "ml-1 #{REVIEW_MARKER_CLASSES}", data: { authenticity_review: certificate.authenticity_status },
      title: "Flagged for review: #{label}. It still counts until someone checks it with the issuer.") do
      safe_join([ tag.span("Review", aria: { hidden: true }), tag.span("Flagged for review", class: "sr-only") ])
    end
  end

  # "Valid", "Expiring", "Lapses on project", "Expired", "Confirmed fake", "Missing", "Not required".
  def status_label(status)
    STATUS_LABELS.fetch(status.to_s) { status.to_s.humanize }
  end

  # Tailwind classes for a status, for callers colouring their own element.
  def compliance_status_classes(status)
    BADGE_CLASSES.fetch(status.to_s, BADGE_CLASSES[NOT_REQUIRED])
  end

  # "Mar 14, 2025"; "—" for nil.
  def format_date(date)
    date ? date.to_date.strftime("%b %-d, %Y") : "—"
  end

  private
    def compliance_badge_parts(cell_or_status, expires_on)
      if cell_or_status.respond_to?(:status)
        [ cell_or_status.status.to_s, expires_on || cell_or_status.expires_on ]
      else
        [ cell_or_status.to_s, expires_on ]
      end
    end
end
