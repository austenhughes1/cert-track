module Ask
  # One line of evidence behind an answer: a person's certificate of a type (nil when they
  # have none), its compliance status ("valid", "expiring", "expired", "missing",
  # "lapses_on_project") and, for gaps and project-filtered lists, the project.
  Item = Data.define(:crew_member, :certificate_type, :certificate, :status, :expires_on, :project) do
    def initialize(crew_member:, certificate_type:, certificate: nil, status: nil, expires_on: nil, project: nil)
      super(crew_member: crew_member, certificate_type: certificate_type, certificate: certificate,
        status: status, expires_on: expires_on || certificate&.expires_on, project: project)
    end
  end
end
