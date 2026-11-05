# "Other..." in a picker (CertificateType, CertificateIssuer): the existing record with a typed name
# or alias, or a new one. A name that is merely close makes a new record: duplicates are accepted
# for now and can be cleaned up later (owner, Nov 5, 2026).
module CreatableFromName
  extend ActiveSupport::Concern

  CREATE_ATTEMPTS = 3

  class_methods do
    # The record with this name or alias, case-insensitive (an active one first, so "Red Cross" finds
    # American Red Cross), or a new one with a code made from the name. Raises on a blank name. The
    # caller tells the user which it was (#previously_new_record?, #name, #active?).
    #
    # Safe when two requests add the same new name at once, inside a transaction too: the insert runs
    # in a savepoint, and a name or code another request took first is looked up (or a new code
    # chosen) again, up to CREATE_ATTEMPTS times.
    def find_or_create_from_name!(name)
      name = name.to_s.squish
      raise ActiveRecord::RecordInvalid, new(name: name).tap(&:validate) if name.blank?

      attempts = 0
      begin
        named(name) || transaction(requires_new: true) { create!(name: name, code: unique_code_for(name), **defaults_from_name) }
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
        raise if error.is_a?(ActiveRecord::RecordInvalid) && !taken?(error.record)
        raise if (attempts += 1) >= CREATE_ATTEMPTS

        retry
      end
    end

    # The record whose name or one of whose aliases is name, case-insensitive: an exact name first,
    # then an active record's alias, then an inactive one's. nil when none.
    def named(name)
      find_by(name: name) || # citext
        where("EXISTS (SELECT 1 FROM unnest(#{table_name}.aliases) AS record_alias WHERE lower(record_alias) = lower(?))", name)
          .order(active: :desc).ordered.first
    end

    private
      # A uniqueness error on name or code: another request got there first.
      def taken?(record)
        record.errors.of_kind?(:name, :taken) || record.errors.of_kind?(:code, :taken)
      end

      def unique_code_for(name)
        base = name.upcase.gsub(/[^A-Z0-9]+/, "").first(20).presence || code_for_unnamed
        candidate = base
        suffix = 1
        while exists?(code: candidate)
          suffix += 1
          candidate = "#{base}-#{suffix}"
        end
        candidate
      end
  end
end
