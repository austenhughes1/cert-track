module Ask
  # A "Did you mean ...?" choice: the record, how to show it, and the question asked again
  # with its name in place of the unclear words. pins pin the record by id when the
  # question is re-asked, so two people with the same name can still be told apart.
  Candidate = Data.define(:record, :label, :detail, :question) do
    def pins
      case record
      when CrewMember then { crew_member_id: record.id }
      when CertificateType then { certificate_type_id: record.id }
      when Project then { project_id: record.id }
      else {}
      end
    end
  end
end
