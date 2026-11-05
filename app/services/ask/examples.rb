module Ask
  # Example questions for the Ask page, built from the real roster, certificate types and
  # projects so every chip gives a real answer. Generic names stand in on an empty database.
  class Examples
    FALLBACK_PERSON = "Juan Ortiz".freeze
    FALLBACK_TYPES = [ "OSHA 30", "Flagger" ].freeze

    def to_a
      person = CrewMember.active.ordered.first&.display_name || FALLBACK_PERSON
      types = CertificateType.active.ordered.limit(2).pluck(:name)
      first_type, second_type = types.size == 2 ? types : FALLBACK_TYPES
      project = Project.active.ordered.pick(:code, :name)&.compact&.first

      [
        "Does #{person} have #{first_type}?",
        "Who has #{second_type}?",
        "What does #{person} have?",
        "What expires in the next 60 days?",
        project ? "What's missing on #{project}?" : "What's missing?"
      ]
    end
  end
end
