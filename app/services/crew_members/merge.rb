module CrewMembers
  # Folds one crew member record into another, for two records of the same person (owner, Nov 7,
  # 2026). The kept record (into) takes over everything the other (from) has, and from is deleted:
  #
  # - certificates: all of them, history included. Where both have a current one of a type, the one
  #   Certificate.currency_order ranks first stays current and the other goes into history. Rows are
  #   moved directly, so expiry alerts already sent aren't sent again (they were about this person),
  #   and a person's issuer check keeps its record of who it was about.
  # - project assignments: each project once; when both are on a project, into's assignment stays,
  #   with its own dates (a blank end is ongoing), taking from's role override where it has none.
  # - import items matched to from, and from in waiting cards' suggestions.
  # - names: from's full name, preferred name and other spellings become into's other spellings,
  #   so their cards match exactly; blank details (preferred name, email, phone, employer, role)
  #   are filled from from; notes are joined; active or expiry emails if either has them on.
  # - possible duplicate marks pointing at from now point at into (and into's own at from is cleared).
  #
  #   result = CrewMembers::Merge.new(from: duplicate, into: kept).call
  #   result.certificates # => 3 (moved)
  #   CrewMembers::Merge.new(from: duplicate, into: kept).preview # same counts, nothing changed
  #
  # Raises Invalid for a record merged into itself.
  class Merge
    class Invalid < StandardError; end

    Preview = Data.define(:certificates, :shared_types, :projects, :shared_projects, :import_items)
    Result = Data.define(:crew_member, :certificates, :projects, :import_items)
    FILLED_IN = %i[preferred_name email phone employer crew_role_id].freeze

    def initialize(from:, into:)
      raise Invalid, "Choose a different crew member to merge into." if from.nil? || into.nil? || from.id == into.id

      @from = from
      @into = into
    end

    # What a merge would move: counts, and the certificate types and projects both records have.
    def preview
      shared_type_ids = current_type_ids(@from) & current_type_ids(@into)
      shared_project_ids = @from.project_assignments.pluck(:project_id) & @into.project_assignments.pluck(:project_id)
      Preview.new(certificates: @from.certificates.count, shared_types: CertificateType.where(id: shared_type_ids).order(:name).to_a,
        projects: @from.project_assignments.count, shared_projects: Project.where(id: shared_project_ids).order(:name).to_a,
        import_items: ImportItem.where(matched_crew_member_id: @from.id).count)
    end

    def call
      CrewMember.transaction do
        CrewMember.where(id: [ @from.id, @into.id ].sort).order(:id).lock.to_a
        @from.reload
        @into.reload
        certificates = move_certificates
        projects = move_project_assignments
        import_items = move_import_items
        move_duplicate_marks
        take_over_details
        @from.reload.destroy!
        Result.new(crew_member: @into, certificates:, projects:, import_items:)
      end
    end

    private
      def current_type_ids(member)
        member.certificates.current.pluck(:certificate_type_id)
      end

      def move_certificates
        moving = Certificate.where(crew_member_id: @from.id)
        type_ids = moving.distinct.pluck(:certificate_type_id)
        now = Time.current
        # Off the one-current-per-member-and-type index first; reconcile_current! picks again below.
        moving.current.where(certificate_type_id: current_type_ids(@into)).update_all(superseded_at: now, updated_at: now)
        restamp_checked_person(moving)
        count = moving.update_all(crew_member_id: @into.id, updated_at: now)
        type_ids.each { |type_id| Certificate.reconcile_current!(@into.id, type_id) }
        count
      end

      def move_project_assignments
        kept = @into.project_assignments.index_by(&:project_id)
        @from.project_assignments.to_a.each do |assignment|
          if (own = kept[assignment.project_id])
            own.update!(crew_role_id: own.crew_role_id || assignment.crew_role_id)
            assignment.destroy!
          else
            assignment.update!(crew_member_id: @into.id)
          end
        end.size
      end

      def move_import_items
        matched = ImportItem.where(matched_crew_member_id: @from.id)
        restamp_checked_person(matched)
        count = matched.update_all(matched_crew_member_id: @into.id, updated_at: Time.current)
        ImportItem.where("person_suggestions @> ?", [ { id: @from.id } ].to_json).find_each do |item|
          item.update_columns(person_suggestions: suggestions_without_from(item.person_suggestions))
        end
        count
      end

      # The person a check was about is stored as a keyed digest of the member id (Authenticity):
      # it is the same person, so the record says so rather than "the person changed".
      def restamp_checked_person(scope)
        from_digest = Authenticity.input_digest(@from.id)
        into_digest = Authenticity.input_digest(@into.id)
        scope.where("authenticity_details -> ? ->> 'person' = ?", Authenticity::CHECKED_INPUTS_KEY, from_digest).find_each do |record|
          details = record.authenticity_details.deep_dup
          details[Authenticity::CHECKED_INPUTS_KEY]["person"] = into_digest
          record.update_columns(authenticity_details: details)
        end
      end

      def suggestions_without_from(suggestions)
        listed = Array(suggestions)
        already = listed.any? { |suggestion| suggestion.respond_to?(:key?) && suggestion["id"].to_i == @into.id }
        listed.filter_map do |suggestion|
          next suggestion unless suggestion.respond_to?(:key?) && suggestion["id"].to_i == @from.id
          suggestion.merge("id" => @into.id, "name" => @into.full_name) unless already
        end
      end

      def move_duplicate_marks
        CrewMember.where(possible_duplicate_of_id: @from.id).where.not(id: @into.id).update_all(possible_duplicate_of_id: @into.id)
        @into.possible_duplicate_of_id = nil if [ @from.id, @into.id ].include?(@into.possible_duplicate_of_id)
      end

      def take_over_details
        FILLED_IN.each { |field| @into[field] = @from[field] if @into[field].blank? }
        @into.notes = [ @into.notes, @from.notes ].compact_blank.uniq.join("\n\n").presence
        @into.active ||= @from.active
        @into.expiry_emails_opt_in ||= @from.expiry_emails_opt_in
        spellings = [ @from.full_name, ("#{@from.preferred_name} #{@from.last_name}" if @from.preferred_name.present?), *@from.name_aliases ]
        @into.name_aliases += spellings.compact.reject { |spelling| @into.normalized_names.include?(NameNormalizer.normalize(spelling)) }
        @into.save!
      end
  end
end
