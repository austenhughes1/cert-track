module CrewMembersHelper
  ACTIVE_FILTER_OPTIONS = [ [ "Active", "" ], [ "Inactive", "inactive" ], [ "Active and inactive", "all" ] ].freeze

  STATUS_FILTER_LABELS = {
    "expired" => "Has expired",
    "missing" => "Has missing",
    "expiring" => "Has expiring (30 days)",
    "lapses_on_project" => "Lapses on a project"
  }.freeze

  def crew_member_active_filter_options
    ACTIVE_FILTER_OPTIONS
  end

  # Statuses the index can filter on, most severe first.
  def crew_member_status_filter_options
    STATUS_FILTER_LABELS.map { |status, label| [ label, status ] }
  end

  def crew_member_role_filter_options(crew_roles)
    [ [ "No role", "none" ], *crew_roles.map { |role| [ role.name, role.id.to_s ] } ]
  end

  # True when anything beyond the default (active members, no search) narrows the list.
  def crew_member_filters_applied?(filters)
    filters.values_at(:q, :active, :employer, :crew_role_id, :status).any?(&:present?)
  end

  # Value for the one-alias-per-line textarea.
  def crew_member_aliases_text(crew_member)
    Array(crew_member.name_aliases).join("\n")
  end

  # Email and phone as links, or an em dash when there are neither.
  def crew_member_contact(crew_member)
    parts = []
    parts << mail_to(crew_member.email, class: "text-blue-700 hover:underline") if crew_member.email.present?
    parts << link_to(crew_member.phone, "tel:#{crew_member.phone.gsub(/[^\d+]/, "")}", class: "text-gray-700 hover:underline") if crew_member.phone.present?
    return tag.span("—", class: "text-gray-400") if parts.empty?

    safe_join(parts, tag.span(" · ", class: "text-gray-300"))
  end
end
