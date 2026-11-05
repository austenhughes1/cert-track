# Who issues certificates, and how each issuer's certificates are verified (docs/PLAN.md, Phase 3b).
# A master list like CertificateType: defaults come from config/certificate_issuers.yml, admins edit
# them at /certificate_issuers, and "Other..." in an issuer picker adds one from a typed name.
class CertificateIssuer < ApplicationRecord
  FUZZY_THRESHOLD = 0.45
  DEFAULTS_FILE = Rails.root.join("config/certificate_issuers.yml")
  CODE_PLACEHOLDER = "{code}".freeze
  CREATE_ATTEMPTS = 3

  enum :verification_method, { unknown: 0, qr_or_code: 1, code_lookup: 2, contact: 3, no_registry: 4 },
    prefix: :verified_by, default: :unknown, validate: true

  has_many :certificates, dependent: :restrict_with_error
  has_many :matched_import_items, class_name: "ImportItem", foreign_key: :matched_certificate_issuer_id,
    inverse_of: :matched_certificate_issuer, dependent: :nullify

  normalizes :name, with: ->(name) { name.squish }
  normalizes :code, with: ->(code) { code.strip.upcase }
  normalizes :aliases, with: ->(aliases) { Array(aliases).map { |name| name.to_s.squish }.compact_blank.uniq(&:downcase) }
  normalizes :domains, with: ->(domains) { Array(domains).filter_map { |domain| registrable_domain(domain) }.uniq }
  normalizes :lookup_url, :link_template, :automatic_check, :verification_notes, with: ->(value) { value.strip.presence }

  validates :name, presence: true, uniqueness: true
  validates :code, presence: true, uniqueness: true, format: { with: /\A[A-Z0-9_-]+\z/, message: "may only contain letters, digits, - and _" }
  validates :position, numericality: { only_integer: true }, allow_nil: true
  validates :lookup_url, format: { with: %r{\Ahttps://\S+\z}, message: "must start with https://" }, allow_nil: true
  validates :link_template, format: { with: %r{\Ahttps://\S*\{code\}\S*\z}, message: "must start with https:// and contain {code}" }, allow_nil: true
  validate :automatic_check_is_known

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(arel_table[:position].asc.nulls_last, :name) }

  class << self
    # Case-insensitive, whitespace-tolerant lookup by code ("redcross " finds REDCROSS).
    def find_by_code(code)
      return if code.blank?

      find_by(code: code.to_s.strip.upcase)
    end

    # "https://verify.360training.com/x?y" / "www.RedCross.org" / "redcross.org" -> "360training.com" / "redcross.org".
    # nil for anything without a dotted host. Keeps the last two labels, or three for a two-letter
    # country domain under a generic second level ("example.co.uk").
    def registrable_domain(url_or_host)
      host = host_of(url_or_host)
      domain_of_host(host) if host
    end

    # registrable_domain for a host already taken out of its URL, whatever letters it holds
    # (Verification::Lookalike compares hosts spelled with look-alike letters).
    def domain_of_host(host)
      labels = host.to_s.split(".")
      keep = labels.size >= 3 && labels.last.size == 2 && %w[co com org gov net ac edu].include?(labels[-2]) ? 3 : 2
      labels.last(keep).join(".").presence
    end

    # The host of a URL or bare host, lowercased, without "www." or a trailing dot; nil if none.
    def host_of(url_or_host)
      text = url_or_host.to_s.strip
      return if text.blank?

      text = "https://#{text}" unless text.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
      host = URI.parse(text).host.to_s.downcase.delete_suffix(".").delete_prefix("www.")
      host if host.include?(".") && host.match?(/\A[a-z0-9.-]+\z/)
    rescue URI::InvalidURIError
      nil
    end

    # The active issuer whose domains include the URL's (or host's) registrable domain, or nil.
    def for_url(url_or_host)
      domain = registrable_domain(url_or_host)
      return if domain.nil?

      active.where("? = ANY (domains)", domain).ordered.first
    end

    # [[issuer, similarity], ...] best first, for every issuer whose name or any alias scores at least
    # threshold (pg_trgm similarity, case-insensitive). Chainable: CertificateIssuer.active.fuzzy_match(...).
    def fuzzy_match(text, threshold: FUZZY_THRESHOLD)
      text = text.to_s.squish
      return [] if text.blank?

      binds = { query: text, threshold: threshold }
      score = <<~SQL.squish
        greatest(similarity(certificate_issuers.name::text, :query),
                 coalesce((select max(similarity(a, :query)) from unnest(certificate_issuers.aliases) a), 0))
      SQL

      select("certificate_issuers.*", sanitize_sql([ "#{score} AS match_similarity", binds ]))
        .where(sanitize_sql([ "#{score} >= :threshold", binds ]))
        .order(Arel.sql("match_similarity DESC"), :name)
        .map { |issuer| [ issuer, issuer.match_similarity.to_f ] }
    end

    # "Other..." in an issuer picker: the existing issuer with this name or alias (case-insensitive;
    # an active one first, so "Red Cross" finds American Red Cross), or a new one with a code made
    # from the name and verification_method unknown. Raises on a blank name. IssuerChoice tells the
    # user which it was (#previously_new_record?, #name, #active?).
    #
    # Safe when two requests add the same new name at once, inside a transaction too: the insert runs
    # in a savepoint, and a name or code another request took first is looked up (or a new code
    # chosen) again, up to CREATE_ATTEMPTS times.
    def find_or_create_from_name!(name)
      name = name.to_s.squish
      raise ActiveRecord::RecordInvalid, new(name: name).tap(&:validate) if name.blank?

      attempts = 0
      begin
        named(name) || transaction(requires_new: true) { create!(name: name, code: unique_code_for(name)) }
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
        raise if error.is_a?(ActiveRecord::RecordInvalid) && !taken?(error.record)
        raise if (attempts += 1) >= CREATE_ATTEMPTS

        retry
      end
    end

    # The issuer whose name or one of whose aliases is name, case-insensitive: an exact name first,
    # then an active issuer's alias, then an inactive one's. nil when none.
    def named(name)
      find_by(name: name) || # citext
        where("EXISTS (SELECT 1 FROM unnest(certificate_issuers.aliases) AS issuer_alias WHERE lower(issuer_alias) = lower(?))", name)
          .order(active: :desc).ordered.first
    end

    # The default issuers (config/certificate_issuers.yml), for db/seeds.rb. Existing codes are left as edited.
    def seed_defaults!
      YAML.safe_load_file(DEFAULTS_FILE).each.with_index(1) do |attributes, position|
        find_or_create_by!(code: attributes.fetch("code")) do |issuer|
          issuer.assign_attributes(attributes.except("code").merge("position" => position))
        end
      end
    end

    private
      # A uniqueness error on name or code: another request got there first.
      def taken?(record)
        record.errors.of_kind?(:name, :taken) || record.errors.of_kind?(:code, :taken)
      end

      def unique_code_for(name)
        base = name.upcase.gsub(/[^A-Z0-9]+/, "").first(20).presence || "ISSUER"
        candidate = base
        suffix = 1
        while exists?(code: candidate)
          suffix += 1
          candidate = "#{base}-#{suffix}"
        end
        candidate
      end
  end

  # Whether a URL's host belongs to this issuer.
  def owns_url?(url_or_host)
    domain = self.class.registrable_domain(url_or_host)
    domain.present? && domains.include?(domain)
  end

  # The direct verification link for a code, from link_template; nil without a template or code.
  def link_for(code)
    return if link_template.blank? || code.blank?

    link_template.sub(CODE_PLACEHOLDER, ERB::Util.url_encode(code.to_s.strip))
  end

  def automatic_check?
    automatic_check.present?
  end

  private
    def automatic_check_is_known
      return if automatic_check.blank?
      return if Verification::Checkers::KEYS.include?(automatic_check)

      errors.add(:automatic_check, "is not a known checker (#{Verification::Checkers::KEYS.join(", ")})")
    end
end
