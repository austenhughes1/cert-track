# Certificate line items, nested under a crew member. Each line item holds any number
# of files (front and back of a card, the wallet card and the certificate). Saving a
# newer certificate of the same type supersedes the older one (see Certificate).
# Phase 3b: the issuer picker's "Other..." (certificate_issuer_id "other" plus
# other_issuer_name) adds an issuer as the certificate saves (or finds one by name or alias), and
# a new certificate, or one whose issuer, verification code, link, dates or files changed, is
# checked (Verification::CheckJob,
# which also reads the QR codes on its files; after Certificates::ReadQrCodesJob when files
# were added).
class CertificatesController < ApplicationController
  include IssuerChoice

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
  # What Verification::Run compares: a saved change to any of these checks the certificate again.
  VERIFICATION_FIELDS = %w[certificate_issuer_id verification_code verification_url crew_member_id completed_on expires_on].freeze

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
    extract_issuer_choice(attributes)
    @certificate = @crew_member.certificates.new(attributes)
    stamp_verification

    if attach_files(files) && save_certificate
      check_authenticity_later(files_added: files.any?)
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
    extract_issuer_choice(attributes)
    @certificate.assign_attributes(attributes)
    stamp_verification

    if attach_files(files) && save_certificate
      check_authenticity_later(files_added: files.any?)
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
    attachment_id = params.expect(:attachment_id)
    attachment = @certificate.files_attachments.includes(:blob).find_by(id: attachment_id)
    return file_already_gone(attachment_id) unless attachment

    attachment.purge_later
    redirect_back_or_to edit_crew_member_certificate_path(@crew_member, @certificate),
      notice: "Removed #{attachment.blob.filename}.", status: :see_other
  end

  private
    # The page was loaded before the file was removed, or before Certificates::ShrinkFilesJob
    # swapped it for a smaller copy (which has a new attachment id). Another record's file is a 404.
    def file_already_gone(attachment_id)
      raise ActiveRecord::RecordNotFound if ActiveStorage::Attachment.exists?(attachment_id)

      redirect_to edit_crew_member_certificate_path(@crew_member, @certificate), status: :see_other,
        alert: "That file is no longer on this certificate: it was removed, or replaced by a smaller copy. Check the files below."
    end

    def set_crew_member
      @crew_member = CrewMember.includes(:crew_role).find(params.expect(:crew_member_id))
    end

    def set_certificate
      @certificate = @crew_member.certificates.includes(:certificate_type, :verified_by, :certificate_issuer, :authenticity_checked_by)
        .with_attached_files.find(params.expect(:id))
    end

    # The edit page is named after the saved type, so re-rendering after a blank or
    # unknown type_id still has a title.
    def set_saved_type_name
      @saved_type_name = @certificate.certificate_type.name
    end

    def certificate_params
      params.expect(certificate: [ :certificate_type_id, :certificate_number, :issued_by, :completed_on, :expires_on, :notes,
        :certificate_issuer_id, :other_issuer_name, :verification_code, :verification_url, files: [] ])
    end

    # The issuer picker's choice (IssuerChoice) comes out of the attributes: save_certificate
    # resolves it. @issuer_choice ("other" or nil) and @other_issuer_name refill the form.
    def extract_issuer_choice(attributes)
      @other_issuer_name = attributes.delete(:other_issuer_name).to_s.squish.presence
      @issuer_problems = issuer_choice_problems(issuer_id: attributes[:certificate_issuer_id], other_name: @other_issuer_name,
        verification_url: attributes[:verification_url].to_s.strip)
      return unless other_issuer_chosen?(attributes[:certificate_issuer_id], @other_issuer_name)

      @issuer_choice = OTHER
      attributes.delete(:certificate_issuer_id)
    end

    # With "Other...", the issuer is found or created in the certificate's transaction, so a
    # certificate that doesn't save leaves no new issuer behind (the form shows "Other..." again).
    def save_certificate
      if @issuer_problems.any?
        @certificate.validate
        @issuer_problems.each { |message| @certificate.errors.add(:base, message) }
        return false
      end
      return @certificate.save unless @issuer_choice

      saved = with_chosen_issuer(OTHER, @other_issuer_name) do |issuer|
        @certificate.certificate_issuer = issuer
        @certificate.save || raise(ActiveRecord::Rollback)
      end
      @certificate.certificate_issuer_id = @certificate.certificate_issuer_id_in_database unless saved
      saved
    end

    # A new certificate gets a first check; an edited one only when what the check uses changed:
    # VERIFICATION_FIELDS, or its files (for their QR codes). Network checks run in the job.
    # When files were added, Certificates::ReadQrCodesJob (queued by Certificate) runs the check
    # once it has read them, so it can use a verification link from a QR code: not queued here too.
    def check_authenticity_later(files_added:)
      return if files_added

      changed = @certificate.previously_new_record? || VERIFICATION_FIELDS.any? { @certificate.saved_change_to_attribute?(it) }
      Verification::CheckJob.perform_later(@certificate) if changed
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
      notice = if @certificate.superseded? && @certificate.authenticity_confirmed_fake?
        "#{verb} #{type_name}. It is confirmed fake, so another #{type_name} certificate on file is the current one " \
          "and this one is kept as history."
      elsif @certificate.superseded?
        "#{verb} #{type_name}. A newer #{type_name} certificate is on file, so this one is kept as history."
      else
        "#{verb} #{type_name} for #{@crew_member.display_name}."
      end
      [ notice, (@certificate.authenticity_note if @certificate.authenticity_reset_by_last_save?),
        (other_issuer_sentence(@certificate.certificate_issuer, @other_issuer_name) if @issuer_choice) ].compact.join(" ")
    end
end
