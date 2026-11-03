module Notifications
  # One certificate crossing an expiry threshold, as shown in a digest email.
  # threshold: "d90" | "d60" | "d30" | "d7" | "expired"
  # projects: active projects that require this type for this crew member.
  DigestItem = Data.define(:certificate, :crew_member, :certificate_type, :threshold, :expires_on, :days_left, :projects) do
    def expired?
      threshold == "expired"
    end
  end
end
