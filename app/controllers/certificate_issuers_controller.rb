# The certificate issuers (docs/PLAN.md, Phase 3b): who issues certificates and how each one's
# are verified. A list like certificate types, but admins only, reads included: the
# issuer pickers and authenticity panels show other users what they need. An issuer that
# anything points at is deactivated rather than deleted. Issuers added with "Other..." in an
# issuer picker arrive with no method or domains, and the list points them out to fill in.
class CertificateIssuersController < ApplicationController
  # List filters besides the default (no param), which shows active issuers only.
  # needs_details: added with "Other..." and not filled in since.
  STATUS_FILTERS = %w[needs_details inactive all].freeze

  # How much an issuer is used. Issuers in use can't be deleted, only deactivated.
  Usage = Data.define(:certificates, :current_certificates, :import_matches) do
    def in_use?
      certificates.positive? || import_matches.positive?
    end

    # "4 certificates and 1 import item"
    def to_sentence
      { "certificate" => certificates, "import item" => import_matches }
        .select { |_noun, count| count.positive? }
        .map { |noun, count| "#{count} #{noun.pluralize(count)}" }
        .to_sentence
    end
  end

  require_role :admin
  before_action :set_certificate_issuer, only: %i[edit update destroy]

  def index
    @status = params[:status].presence_in(STATUS_FILTERS)
    @certificate_issuers = filtered(@status).ordered.load
    @usage = usage_by_issuer(@certificate_issuers.map(&:id))
    @counts_by_active = CertificateIssuer.group(:active).count
    @needs_details_count = needing_details.count
  end

  def new
    @certificate_issuer = CertificateIssuer.new
  end

  def create
    @certificate_issuer = CertificateIssuer.new(certificate_issuer_params)

    if @certificate_issuer.save
      redirect_to list_path(@certificate_issuer), notice: "Added #{@certificate_issuer.name} to the issuers."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    set_usage
  end

  def update
    if @certificate_issuer.update(certificate_issuer_params)
      redirect_to list_path(@certificate_issuer), notice: update_notice, status: :see_other
    else
      set_usage
      render :edit, status: :unprocessable_entity
    end
  end

  # Deletes an unused issuer. One that certificates or import items point at is deactivated
  # instead, so they keep it.
  def destroy
    if usage_for(@certificate_issuer).in_use? || !@certificate_issuer.destroy
      deactivate_instead_of_destroying
    else
      redirect_to list_path, notice: "Deleted #{@certificate_issuer.name}.", status: :see_other
    end
  end

  private
    def set_certificate_issuer
      @certificate_issuer = CertificateIssuer.find(params.expect(:id))
    end

    def set_usage
      @usage = usage_for(@certificate_issuer)
    end

    # Aliases arrive from a textarea, one name per line (a printed name may hold a comma);
    # domains from a text field, separated by commas, spaces or new lines.
    def certificate_issuer_params
      params.expect(certificate_issuer: %i[name code aliases domains verification_method lookup_url link_template
        automatic_check verification_notes active position]).tap do |attrs|
        attrs[:aliases] = attrs[:aliases].to_s.split(/[\r\n]+/) if attrs.key?(:aliases)
        attrs[:domains] = attrs[:domains].to_s.split(/[\s,]+/) if attrs.key?(:domains)
      end
    end

    def filtered(status)
      case status
      when "needs_details" then needing_details
      when "inactive" then CertificateIssuer.where(active: false)
      when "all" then CertificateIssuer.all
      else CertificateIssuer.active
      end
    end

    # CertificateIssuersHelper#certificate_issuer_needs_details? as a query.
    def needing_details
      CertificateIssuer.where(verification_method: :unknown, domains: [])
    end

    # Buttons on the list send status so the redirect lands on the same list. Forms don't, so
    # go to a list that shows the record.
    def list_path(certificate_issuer = nil)
      status =
        if params.key?(:status)
          params[:status].presence_in(STATUS_FILTERS)
        elsif certificate_issuer && !certificate_issuer.active?
          "all"
        end
      certificate_issuers_path(status: status)
    end

    def update_notice
      name = @certificate_issuer.name
      if !@certificate_issuer.saved_change_to_active?
        "Saved #{name}."
      elsif @certificate_issuer.active?
        "Reactivated #{name}."
      else
        "Deactivated #{name}. Certificates that name it keep it."
      end
    end

    def deactivate_instead_of_destroying
      name = @certificate_issuer.name
      reason = "#{name} is used by #{usage_for(@certificate_issuer).to_sentence}, so it can't be deleted"

      if !@certificate_issuer.active?
        redirect_to list_path(@certificate_issuer), alert: "#{reason}. It's already inactive.", status: :see_other
      elsif @certificate_issuer.update(active: false)
        redirect_to list_path(@certificate_issuer), status: :see_other,
          notice: "#{reason}. It was deactivated instead: certificates keep it, and you can reactivate it from the Inactive list."
      else
        redirect_to edit_certificate_issuer_path(@certificate_issuer), status: :see_other,
          alert: "#{reason}, and it couldn't be deactivated: #{@certificate_issuer.errors.full_messages.to_sentence}."
      end
    end

    def usage_for(certificate_issuer)
      usage_by_issuer([ certificate_issuer.id ]).fetch(certificate_issuer.id)
    end

    # {issuer_id => Usage} for the given ids, in two grouped queries.
    def usage_by_issuer(issuer_ids)
      return {} if issuer_ids.empty?

      certificates = Certificate.where(certificate_issuer_id: issuer_ids).group(:certificate_issuer_id)
        .pluck(:certificate_issuer_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE superseded_at IS NULL)"))
        .to_h { |id, total, current| [ id, [ total, current ] ] }
      import_matches = ImportItem.where(matched_certificate_issuer_id: issuer_ids).group(:matched_certificate_issuer_id).count

      issuer_ids.index_with do |id|
        total, current = certificates.fetch(id, [ 0, 0 ])
        Usage.new(certificates: total, current_certificates: current, import_matches: import_matches.fetch(id, 0))
      end
    end
end
