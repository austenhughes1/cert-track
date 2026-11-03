# The master list of certificate types. Every signed-in user can read it; only admins
# change it. A type that anything points at is deactivated rather than deleted.
class CertificateTypesController < ApplicationController
  # List filters besides the default (no param), which shows active types only.
  STATUS_FILTERS = %w[inactive all].freeze

  # How much a type is used. Types in use can't be deleted, only deactivated.
  Usage = Data.define(:certificates, :current_certificates, :projects, :import_matches) do
    def in_use?
      certificates.positive? || projects.positive? || import_matches.positive?
    end

    # "4 certificates, 2 projects and 1 import item"
    def to_sentence
      { "certificate" => certificates, "project" => projects, "import item" => import_matches }
        .select { |_noun, count| count.positive? }
        .map { |noun, count| "#{count} #{noun.pluralize(count)}" }
        .to_sentence
    end
  end

  require_role :admin, except: :index
  before_action :set_certificate_type, only: %i[edit update destroy move]

  def index
    @status = params[:status].presence_in(STATUS_FILTERS)
    @certificate_types = filtered(@status).ordered.load
    @usage = usage_by_type(@certificate_types.map(&:id))
    @counts_by_active = CertificateType.group(:active).count
  end

  def new
    @certificate_type = CertificateType.new
  end

  def create
    @certificate_type = CertificateType.new(certificate_type_params)

    if @certificate_type.save
      redirect_to list_path(@certificate_type), notice: "Added #{@certificate_type.name} to the master list."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    set_usage
  end

  def update
    if @certificate_type.update(certificate_type_params)
      redirect_to list_path(@certificate_type), notice: update_notice, status: :see_other
    else
      set_usage
      render :edit, status: :unprocessable_entity
    end
  end

  # Deletes an unused type. A type with certificates, requirements or import matches is
  # deactivated instead, so history and project setups keep pointing at it.
  def destroy
    if usage_for(@certificate_type).in_use? || !@certificate_type.destroy
      deactivate_instead_of_destroying
    else
      redirect_to list_path, notice: "Deleted #{@certificate_type.name}.", status: :see_other
    end
  end

  # Swaps a type with its neighbour in the list being viewed, then renumbers every type
  # 1..N so positions stay unique.
  def move
    step = { "up" => -1, "down" => 1 }[params[:direction]]
    status = params[:status].presence_in(STATUS_FILTERS)

    CertificateType.transaction do
      order = CertificateType.ordered.lock.pluck(:id, :position)
      visible = filtered(status).ordered.ids
      index = visible.index(@certificate_type.id)
      neighbour_index = index + step if index && step

      if neighbour_index&.between?(0, visible.size - 1)
        ids = order.map(&:first)
        a, b = ids.index(@certificate_type.id), ids.index(visible[neighbour_index])
        ids[a], ids[b] = ids[b], ids[a]
        renumber(ids, order.to_h)
      end
    end

    redirect_to certificate_types_path(status: status), status: :see_other
  end

  private
    def set_certificate_type
      @certificate_type = CertificateType.find(params.expect(:id))
    end

    def set_usage
      @usage = usage_for(@certificate_type)
    end

    # Aliases arrive from a textarea, one name per line.
    def certificate_type_params
      params.expect(certificate_type: %i[name code issuing_body validity_months aliases description active position]).tap do |attrs|
        attrs[:aliases] = attrs[:aliases].to_s.split(/[\r\n]+/) if attrs.key?(:aliases)
      end
    end

    def filtered(status)
      case status
      when "inactive" then CertificateType.where(active: false)
      when "all" then CertificateType.all
      else CertificateType.active
      end
    end

    # Buttons on the list send status so the redirect lands on the same list (Turbo then
    # morphs it in place). Forms don't, so go to a list that shows the record.
    def list_path(certificate_type = nil)
      status =
        if params.key?(:status)
          params[:status].presence_in(STATUS_FILTERS)
        elsif certificate_type && !certificate_type.active?
          "all"
        end
      certificate_types_path(status: status)
    end

    def update_notice
      name = @certificate_type.name
      status =
        if !@certificate_type.saved_change_to_active?
          "Saved #{name}."
        elsif @certificate_type.active?
          "Reactivated #{name}."
        else
          "Deactivated #{name}. Existing certificates and project requirements keep it."
        end
      [ status, redated_sentence ].compact.join(" ")
    end

    # Set only when the save changed validity (CertificateType#rederived_certificate_count).
    def redated_sentence
      count = @certificate_type.rederived_certificate_count
      return if count.nil?

      "Re-dated #{helpers.pluralize(count, "certificate")} that had no date from the card."
    end

    def deactivate_instead_of_destroying
      name = @certificate_type.name
      reason = "#{name} is used by #{usage_for(@certificate_type).to_sentence}, so it can't be deleted"

      if !@certificate_type.active?
        redirect_to list_path(@certificate_type), alert: "#{reason}. It's already inactive.", status: :see_other
      elsif @certificate_type.update(active: false)
        redirect_to list_path(@certificate_type), status: :see_other,
          notice: "#{reason}. It was deactivated instead: its history is kept, and you can reactivate it from the Inactive list."
      else
        redirect_to edit_certificate_type_path(@certificate_type), status: :see_other,
          alert: "#{reason}, and it couldn't be deactivated: #{@certificate_type.errors.full_messages.to_sentence}."
      end
    end

    def usage_for(certificate_type)
      usage_by_type([ certificate_type.id ]).fetch(certificate_type.id)
    end

    # {type_id => Usage} for the given ids, in three grouped queries.
    def usage_by_type(type_ids)
      return {} if type_ids.empty?

      certificates = Certificate.where(certificate_type_id: type_ids).group(:certificate_type_id)
        .pluck(:certificate_type_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE superseded_at IS NULL)"))
        .to_h { |id, total, current| [ id, [ total, current ] ] }
      projects = ProjectRequirement.where(certificate_type_id: type_ids).group(:certificate_type_id).distinct.count(:project_id)
      import_matches = ImportItem.where(matched_certificate_type_id: type_ids).group(:matched_certificate_type_id).count

      type_ids.index_with do |id|
        total, current = certificates.fetch(id, [ 0, 0 ])
        Usage.new(certificates: total, current_certificates: current,
          projects: projects.fetch(id, 0), import_matches: import_matches.fetch(id, 0))
      end
    end

    # Writes position = 1..N in the given id order, touching only rows that change.
    def renumber(ids, positions_by_id)
      ids.each.with_index(1) do |id, position|
        CertificateType.where(id: id).update_all(position: position) unless positions_by_id[id] == position
      end
    end
end
