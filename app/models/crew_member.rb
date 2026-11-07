class CrewMember < ApplicationRecord
  SEARCH_SIMILARITY = 0.2 # typo tolerance: "Jaun Ortis" vs "juan ortiz" scores ~0.29
  FULL_NAME_SQL = "lower(crew_members.first_name || ' ' || crew_members.last_name)".freeze # matches the trigram index
  PREFERRED_NAME_SQL = "lower(coalesce(crew_members.preferred_name, crew_members.first_name) || ' ' || crew_members.last_name)".freeze

  belongs_to :crew_role, optional: true

  # History is kept: members with certificates or assignments are deactivated, not deleted.
  has_many :certificates, dependent: :restrict_with_error
  has_many :current_certificates, -> { current }, class_name: "Certificate", inverse_of: :crew_member
  has_many :project_assignments, dependent: :restrict_with_error
  has_many :projects, through: :project_assignments
  has_many :matched_import_items, class_name: "ImportItem", foreign_key: :matched_crew_member_id,
    inverse_of: :matched_crew_member, dependent: :nullify

  normalizes :first_name, :last_name, with: ->(name) { name.squish }
  normalizes :preferred_name, :phone, :employer, with: ->(value) { value.squish.presence }
  normalizes :email, with: ->(email) { email.strip.downcase.presence }
  normalizes :name_aliases, with: ->(aliases) { CrewMember.clean_aliases(aliases) }

  validates :first_name, :last_name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :ordered, -> { order(:last_name, :first_name, :id) }

  class << self
    # Typo-tolerant name search over full name, preferred name and aliases, best match first.
    # Blank query returns the relation unchanged. Chainable (count/pagination safe).
    def search(query)
      q = query.to_s.squish.downcase
      return all if q.blank?

      binds = { q: q, like: "%#{sanitize_sql_like(q)}%", threshold: SEARCH_SIMILARITY }
      alias_score = "coalesce((select max(similarity(lower(a), :q)) from unnest(crew_members.name_aliases) a), 0)"
      score = "greatest(similarity(#{FULL_NAME_SQL}, :q), similarity(#{PREFERRED_NAME_SQL}, :q), #{alias_score})"
      matches = <<~SQL.squish
        #{FULL_NAME_SQL} like :like
        or #{PREFERRED_NAME_SQL} like :like
        or exists (select 1 from unnest(crew_members.name_aliases) a where lower(a) like :like)
        or #{score} >= :threshold
      SQL

      where(sanitize_sql([ matches, binds ]))
        .order(Arel.sql(sanitize_sql([ "#{score} desc", binds ])), :last_name, :first_name, :id)
    end

    # Members whose full name, preferred + last name, or any alias normalizes to the same
    # string as raw (see NameNormalizer). Active members first. A single-token name (a bare
    # surname like "SMITH") matches nobody: it can't tell two Smiths apart. Loads names in
    # Ruby; fine for a roster of hundreds.
    def matching_normalized_name(raw)
      target = NameNormalizer.normalize(raw)
      return [] unless NameNormalizer.matchable?(target)

      all.order(active: :desc, id: :asc).select { |member| member.normalized_names.include?(target) }
    end

    # Members whose name, preferred name or alias is raw with middle names on one side only
    # (NameNormalizer.differs_only_by_middle?): "Shamel Ferebee" finds "Shamel Deshawn Ferebee"
    # and the other way round. Active members first. Imports::PersonMatcher uses it when no name
    # matches exactly.
    def matching_name_ignoring_middle(raw)
      target = NameNormalizer.normalize(raw)
      return [] unless NameNormalizer.matchable?(target)

      all.order(active: :desc, id: :asc).select do |member|
        member.normalized_names.any? { |name| NameNormalizer.differs_only_by_middle?(name, target) }
      end
    end

    # Single best exact normalized match (prefers active members), or nil.
    def find_by_normalized_name(raw)
      matching_normalized_name(raw).first
    end

    # Distinct employers for filter dropdowns.
    def employer_names
      where.not(employer: nil).distinct.order(:employer).pluck(:employer)
    end

    def clean_aliases(aliases)
      Array(aliases).map { |name| name.to_s.squish }.compact_blank.uniq(&:downcase)
    end
  end

  def full_name
    "#{first_name} #{last_name}"
  end

  # "Johnny Ortiz" when preferred_name is set, else "Juan Ortiz".
  def display_name
    "#{preferred_name.presence || first_name} #{last_name}"
  end

  # "Ortiz, Juan" for sorted lists.
  def sort_name
    "#{last_name}, #{first_name}"
  end

  def normalized_names
    names = [ full_name, ("#{preferred_name} #{last_name}" if preferred_name.present?), *name_aliases ]
    names.compact.map { |name| NameNormalizer.normalize(name) }.compact_blank.uniq
  end

  # Records a spelling seen on a card. No-op (returns false) when it normalizes to a name
  # we already know, or to fewer than two tokens ("Smith", "J."), which could be anyone.
  def add_alias!(raw)
    spelling = raw.to_s.squish
    normalized = NameNormalizer.normalize(spelling)
    return false if !NameNormalizer.matchable?(normalized) || normalized_names.include?(normalized)

    update!(name_aliases: name_aliases + [ spelling ])
    true
  end

  # Current certificate of the given type (uses current_certificates if preloaded).
  def current_certificate_for(certificate_type)
    type_id = certificate_type.is_a?(CertificateType) ? certificate_type.id : certificate_type
    if current_certificates.loaded?
      current_certificates.find { |certificate| certificate.certificate_type_id == type_id }
    else
      current_certificates.find_by(certificate_type_id: type_id)
    end
  end
end
