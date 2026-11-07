module CrewMembers
  # The crew member most likely to be the same person as a name, for marking a new member a possible
  # duplicate (CrewMember#possible_duplicate_of), other than except: the best Imports::PersonMatcher
  # candidate scoring Imports::Config.person_suggest_threshold or more, else one whose name has
  # each word at most a letter off (NameNormalizer.each_word_within_one_edit?: "Jaun Ortis" for
  # "Juan Ortiz", which scores low). nil when nobody is that close.
  #
  #   CrewMembers::DuplicateFinder.new("Shamel Ferebe").call                 # => #<CrewMember Shamel Ferebee>
  #   CrewMembers::DuplicateFinder.new(member.full_name, except: member).call
  class DuplicateFinder
    def initialize(name, except: nil)
      @name = name
      @except_id = except&.id
    end

    def call
      found = Imports::PersonMatcher.new(@name).call.suggestions.find do |suggestion|
        suggestion["id"] != @except_id && suggestion["similarity"].to_f + Imports::PersonMatcher::EPSILON >= Imports::Config.person_suggest_threshold
      end
      return CrewMember.find_by(id: found["id"]) if found

      target = NameNormalizer.normalize(@name)
      CrewMember.where.not(id: @except_id).order(active: :desc, id: :asc).find do |member|
        member.normalized_names.any? { |name| NameNormalizer.each_word_within_one_edit?(name, target) }
      end
    end
  end
end
