# Certificate line items, nested under a crew member. Each line item holds any number
# of files (front and back of a card, the wallet card and the certificate). Saving a
# newer certificate of the same type supersedes the older one (see Certificate).
class CertificatesController < ApplicationController
  require_role :editor, except: :show
  require_role :admin, only: :destroy

  before_action :set_crew_member
  before_action :set_certificate, only: %i[show edit update destroy remove_file]
  before_action :set_saved_type_name, only: %i[edit update]

  # Signed blob ids that are tampered with, point at a deleted blob or at a direct upload
  # that never finished.
  UNREADABLE_FILE_ERRORS = [
    ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound, ActiveStorage::FileNotFoundError
  ].freeze

  def show
    @history = @crew_member.certificates.where(certificate_type_id: @certificate.certificate_type_id)
      .where.not(id: @certificate.id).chronological.with_attached_files.to_a
  end

  # params[:certificate_type_id] preselects the type (e.g. from a "missing" matrix cell).
  def new
    @certificate = @crew_member.certificates.new(certificate_type: CertificateType.active.find_by(id: params[:certificate_type_id]))
  end

  def create
    attributes = certificate_params
    files = extract_files(attributes)
    @certificate = @crew_member.certificates.new(attributes)
    stamp_verification

    if attach_files(files) && @certificate.save
      redirect_to crew_member_certificate_path(@crew_member, @certificate), notice: saved_notice("Added")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # Files in the form are added to the ones already attached; remove_file deletes one.
  def update
    attributes = certificate_params
    files = extract_files(attributes)
    @certificate.assign_attributes(attributes)
    stamp_verification

    if attach_files(files) && @certificate.save
      redirect_to crew_member_certificate_path(@crew_member, @certificate), notice: saved_notice("Saved"), status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Admin only. If this was the current certificate, the previous one becomes current again.
  def destroy
    name = @certificate.certificate_type.name
    if @certificate.destroy
      redirect_to crew_member_path(@crew_member), notice: "Deleted the #{name} certificate.", status: :see_other
    else
      redirect_to crew_member_certificate_path(@crew_member, @certificate), alert: @certificate.errors.full_messages.to_sentence,
        status: :see_other
    end
  end

  def remove_file
    attachment = @certificate.files_attachments.includes(:blob).find(params.expect(:attachment_id))
    attachment.purge_later
    redirect_back_or_to edit_crew_member_certificate_path(@crew_member, @certificate),
      notice: "Removed #{attachment.blob.filename}.", status: :see_other
  end

  private
    def set_crew_member
      @crew_member = CrewMember.includes(:crew_role).find(params.expect(:crew_member_id))
    end

    def set_certificate
      @certificate = @crew_member.certificates.includes(:certificate_type, :verified_by).with_attached_files.find(params.expect(:id))
    end

    # The edit page is named after the saved type, so re-rendering after a blank or
    # unknown type_id still has a title.
    def set_saved_type_name
      @saved_type_name = @certificate.certificate_type.name
    end

    def certificate_params
      params.expect(certificate: [ :certificate_type_id, :certificate_number, :issued_by, :completed_on, :expires_on, :notes, files: [] ])
    end

    # Signed ids from direct uploads (or uploaded files without JS); blanks come from the
    # file field's hidden "" input.
    def extract_files(attributes)
      Array(attributes.delete(:files)).compact_blank
    end

    # Appends: assigning files= would replace the files already attached.
    def attach_files(files)
      @certificate.files.attach(files) if files.any?
      true
    rescue *UNREADABLE_FILE_ERRORS
      @certificate.errors.add(:files, "could not be read. Upload them again.")
      false
    end

    # Entered or checked by hand, so whoever saved it vouches for it.
    def stamp_verification
      @certificate.source = :manual if @certificate.new_record?
      @certificate.verified_by = Current.user
      @certificate.verified_at = Time.current
    end

    def saved_notice(verb)
      type_name = @certificate.certificate_type.name
      if @certificate.superseded?
        "#{verb} #{type_name}. A newer #{type_name} certificate is on file, so this one is kept as history."
      else
        "#{verb} #{type_name} for #{@crew_member.display_name}."
      end
    end
end
