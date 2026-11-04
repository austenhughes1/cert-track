module Ask
  # One row of a project's requirements in an Ask answer: a certificate type, the roles
  # that need it (empty: everyone), the requirements' notes, and how many people on the
  # crew need it and how many of them have no current one (missing or expired).
  Requirement = Data.define(:certificate_type, :crew_roles, :notes, :needed, :missing) do
    def everyone?
      crew_roles.empty?
    end
  end
end
