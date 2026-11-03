module ComplianceHelper
  NOT_REQUIRED = Compliance::ProjectReport::NOT_REQUIRED

  # Full class strings so Tailwind's scanner picks them up.
  BADGE_BASE = "inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium tabular-nums".freeze
  BADGE_CLASSES = {
    "valid" => "bg-green-100 text-green-800 ring-1 ring-inset ring-green-600/20",
    "expiring" => "bg-amber-100 text-amber-800 ring-1 ring-inset ring-amber-600/30",
    "lapses_on_project" => "bg-orange-100 text-orange-800 ring-1 ring-inset ring-orange-600/30",
    "expired" => "bg-red-600 text-white ring-1 ring-inset ring-red-700",
    "missing" => "bg-white text-red-700 ring-1 ring-inset ring-red-500",
    NOT_REQUIRED => "text-gray-400"
  }.freeze

  STATUS_LABELS = Compliance::LABELS.merge(NOT_REQUIRED => "Not required").freeze

  # A coloured pill for a ProjectReport::Cell or a bare status. Shows the expiry date
  # when there is one, otherwise the status label; not_required is a grey dash.
  def compliance_badge(cell_or_status, expires_on = nil)
    status, expires_on = compliance_badge_parts(cell_or_status, expires_on)
    label = status_label(status)
    classes = "#{BADGE_BASE} #{compliance_status_classes(status)}"

    if status == NOT_REQUIRED
      tag.span("—", class: classes, title: label, data: { status: status })
    elsif expires_on
      verb = status == "expired" ? "expired" : "expires"
      tag.span(class: classes, title: "#{label}: #{verb} #{format_date(expires_on)}", data: { status: status }) do
        safe_join([ tag.span("#{label}, ", class: "sr-only"), format_date(expires_on) ])
      end
    else
      title = status == "valid" && cell_or_status.respond_to?(:certificate) ? "#{label}: never expires" : label
      tag.span(label, class: classes, title: title, data: { status: status })
    end
  end

  # "Valid", "Expiring", "Lapses on project", "Expired", "Missing", "Not required".
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
