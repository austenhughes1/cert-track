# The list of certificate types.
class CertificateType < ApplicationRecord
  include CreatableFromName

  FUZZY_THRESHOLD = 0.45
  # Owner's rule, Nov 5, 2026: a certificate that states no expiry or validity lasts 2 years. New
  # types start with this; a blank validity means the type never expires (OSHA 10 and 30).
  DEFAULT_VALIDITY_MONTHS = 24

  has_many :certificates, dependent: :restrict_with_error
  has_many :project_requirements, dependent: :restrict_with_error
  has_many :projects, -> { distinct }, through: :project_requirements
  has_many :matched_import_items, class_name: "ImportItem", foreign_key: :matched_certificate_type_id,
    inverse_of: :matched_certificate_type, dependent: :nullify

  normalizes :name, with: ->(name) { name.squish }
  normalizes :code, with: ->(code) { code.strip.upcase }
  normalizes :issuing_body, with: ->(value) { value.squish.presence }
  normalizes :aliases, with: ->(aliases) { Array(aliases).map { |name| name.to_s.squish }.compact_blank.uniq(&:downcase) }

  validates :name, presence: true, uniqueness: true
  validates :code, presence: true, uniqueness: true, format: { with: /\A[A-Z0-9_-]+\z/, message: "may only contain letters, digits, - and _" }
  validates :validity_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :position, numericality: { only_integer: true }, allow_nil: true

  after_update :rederive_certificate_expiries, if: :saved_change_to_validity_months?

  # How many certificates the last validity change in this instance re-dated; nil until one.
  attr_reader :rederived_certificate_count

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(arel_table[:position].asc.nulls_last, :name) }

  class << self
    # Case-insensitive, whitespace-tolerant lookup by code ("osha30 " finds OSHA30).
    def find_by_code(code)
      return if code.blank?

      find_by(code: code.to_s.strip.upcase)
    end

    # [[type, similarity], ...] best first, for every type whose name or any alias scores
    # at least threshold (pg_trgm, case-insensitive). Chainable scope first:
    # CertificateType.active.fuzzy_match("OSHA 30 hr"). Training providers word the same certificate
    # differently, usually by adding to it ("Bloodborne Pathogens Online Training"), so a name or
    # alias found whole inside the text scores as well as the text overall (word_similarity).
    def fuzzy_match(text, threshold: FUZZY_THRESHOLD)
      text = text.to_s.squish
      return [] if text.blank?

      binds = { query: text, threshold: threshold }
      score = <<~SQL.squish
        greatest(similarity(certificate_types.name::text, :query), word_similarity(certificate_types.name::text, :query),
                 coalesce((select max(greatest(similarity(a, :query), word_similarity(a, :query)))
                           from unnest(certificate_types.aliases) a), 0))
      SQL

      select("certificate_types.*", sanitize_sql([ "#{score} AS match_similarity", binds ]))
        .where(sanitize_sql([ "#{score} >= :threshold", binds ]))
        .order(Arel.sql("match_similarity DESC"), :name)
        .map { |type| [ type, type.match_similarity.to_f ] }
    end
  end

  def never_expires?
    validity_months.nil?
  end

  # completed_on + validity_months, or nil when the type never expires.
  def expiry_for(completed_on)
    return if completed_on.nil? || never_expires?

    completed_on.advance(months: validity_months)
  end

  private_class_method def self.defaults_from_name = { validity_months: DEFAULT_VALIDITY_MONTHS }
  private_class_method def self.code_for_unnamed = "TYPE"

  private
    # Setting or changing validity re-derives certificates that never expired and every computed
    # date, current and history alike (see Certificate#rederive_expiry!). Runs inside the
    # type's save transaction, so the type and its certificates change together.
    def rederive_certificate_expiries
      @rederived_certificate_count = 0
      certificates.where(expires_on_source: %i[computed none]).find_each do |certificate|
        certificate.certificate_type = self
        @rederived_certificate_count += 1 if certificate.rederive_expiry!
      end
    end
end
