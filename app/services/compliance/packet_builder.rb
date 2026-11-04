require "zip"

module Compliance
  # Builds a project's compliance packet: a zip holding index.pdf plus every file of
  # every current certificate in a required cell of the project's matrix (active crew,
  # types their role needs on the project). Superseded certificates and certificates
  # for types a person doesn't need are left out.
  #
  # Files are named "Last_First - CODE - exp YYYY-MM-DD.ext" ("exp none" when the
  # certificate never expires); repeats get " (2)", " (3)" and so on. Each file is
  # streamed through a temp file (blob.open), so memory stays flat however big the
  # packet gets.
  #
  #   builder = Compliance::PacketBuilder.new(project)
  #   builder.entries               # => [Entry(name:, crew_member:, certificate_type:, certificate:, blob:)]
  #   builder.write_zip(path)       # writes the zip to path
  #   builder.attach!(built_by: user) # builds in a temp dir, attaches project.packet, sets packet_built_at,
  #                                   # and records a PacketBuild holding a copy of index.pdf
  class PacketBuilder
    INDEX_NAME = "index.pdf".freeze
    MAX_PART_LENGTH = 60
    EXTENSIONS_BY_CONTENT_TYPE = {
      "application/pdf" => "pdf", "image/jpeg" => "jpg", "image/png" => "png",
      "image/heic" => "heic", "image/heif" => "heif", "image/webp" => "webp"
    }.freeze

    Entry = Data.define(:name, :crew_member, :certificate_type, :certificate, :blob)

    attr_reader :project, :today

    # A file-name-safe project code (or id) for packet and export file names.
    def self.slug_for(project)
      project.code.to_s.gsub(/[^A-Za-z0-9_-]+/, "-").squeeze("-").delete_prefix("-").delete_suffix("-").presence || project.id.to_s
    end

    # One path component: ASCII only, no path separators or control characters, odd
    # characters collapsed to "_", no leading dots.
    def self.sanitize(text, max_length: MAX_PART_LENGTH)
      ascii = I18n.transliterate(text.to_s.unicode_normalize(:nfc), replacement: "_")
      cleaned = ascii.gsub(/[[:cntrl:]]/, "").tr("/\\", "  ").gsub(/[^A-Za-z0-9 ._'(),&+-]/, "_")
      cleaned = cleaned.squeeze("_").squish.sub(/\A[.\s_]+/, "").sub(/[.\s]+\z/, "")
      cleaned.first(max_length).rstrip.presence || "unnamed"
    end

    def initialize(project, today: Date.current, report: nil)
      @project = project
      @today = today
      @report = report
    end

    def report
      @report ||= ProjectReport.new(project, today: today)
    end

    def filename
      "#{self.class.slug_for(project)}-packet-#{today.iso8601}.zip"
    end

    # Name of the index.pdf copy kept on the PacketBuild, e.g. "2417-packet-2026-11-04-index.pdf".
    def index_filename
      "#{File.basename(filename, ".zip")}-index.pdf"
    end

    # Required cells with a current certificate, in matrix order: [row, cell] pairs.
    def certificate_cells
      @certificate_cells ||= report.rows.flat_map do |row|
        report.columns.filter_map do |type|
          cell = row.cell_for(type)
          [ row, cell ] if cell.required? && cell.certificate
        end
      end
    end

    # Array<Entry>: one per file, in matrix order, with unique names.
    def entries
      @entries ||= begin
        preload_files
        used = Set[INDEX_NAME]
        certificate_cells.flat_map do |row, cell|
          cell.certificate.files.map do |file|
            name = unique_name(entry_stem(row.crew_member, cell.certificate_type, cell.certificate), extension_for(file.blob), used)
            Entry.new(name: name, crew_member: row.crew_member, certificate_type: cell.certificate_type,
              certificate: cell.certificate, blob: file.blob)
          end
        end
      end
    end

    # PDF bytes for index.pdf.
    def index_pdf(generated_at: Time.current)
      PacketIndexPdf.new(project: project, rows: index_rows, gaps: index_gaps, summary: report.summary,
        generated_at: generated_at).render
    end

    # Writes the packet to path (index.pdf first, then the files) and returns path.
    def write_zip(path, index: index_pdf)
      Zip::OutputStream.open(path) do |zip|
        zip.put_next_entry(INDEX_NAME)
        zip.write(index)

        entries.each do |entry|
          zip.put_next_entry(entry.name)
          entry.blob.open { |file| IO.copy_stream(file, zip) }
        end
      end
      path
    end

    # Builds the zip in a temp directory, uploads it, attaches it as project.packet
    # (replacing any earlier packet) and stamps project.packet_built_at. Also records a
    # PacketBuild (built_by: a User or nil) holding a copy of this build's index.pdf, which
    # outlives the zip. packet_built_at and the build's built_at are the time printed on
    # the index. Both files are uploaded before anything is saved; a blob left behind by a
    # failed save is caught by Maintenance::PurgeUnattachedBlobsJob.
    def attach!(built_by: nil)
      built_at = Time.current
      index = index_pdf(generated_at: built_at)

      Dir.mktmpdir("packet") do |dir|
        path = write_zip(File.join(dir, filename), index: index)
        zip_blob = File.open(path, "rb") do |io|
          ActiveStorage::Blob.create_and_upload!(io: io, filename: filename, content_type: "application/zip")
        end
        index_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(index), filename: index_filename,
          content_type: "application/pdf")

        Project.transaction do
          project.update!(packet: zip_blob, packet_built_at: built_at)
          project.packet_builds.create!(built_by: built_by, built_at: built_at, packet_filename: filename,
            certificate_count: certificate_cells.size, file_count: entries.size, gap_count: report.gaps.size,
            index_pdf: index_blob)
        end
      end
      project.packet
    end

    private
      def preload_files
        ActiveRecord::Associations::Preloader.new(
          records: certificate_cells.map { |_, cell| cell.certificate }, associations: { files_attachments: :blob }
        ).call
      end

      def entry_stem(member, type, certificate)
        person = "#{self.class.sanitize(member.last_name)}_#{self.class.sanitize(member.first_name)}"
        expiry = certificate.expires_on ? "exp #{certificate.expires_on.iso8601}" : "exp none"
        "#{person} - #{self.class.sanitize(type.code)} - #{expiry}"
      end

      def extension_for(blob)
        extension = blob.filename.extension.to_s.downcase.gsub(/[^a-z0-9]/, "").first(10)
        extension.presence || EXTENSIONS_BY_CONTENT_TYPE[blob.content_type]
      end

      # Appends " (2)", " (3)"... until the name is unused. Compared case-insensitively
      # so the zip extracts cleanly on Windows and macOS.
      def unique_name(stem, extension, used)
        suffix = extension ? ".#{extension}" : ""
        name = "#{stem}#{suffix}"
        counter = 1
        name = "#{stem} (#{counter += 1})#{suffix}" while used.include?(name.downcase)
        used << name.downcase
        name
      end

      def index_rows
        names_by_certificate = entries.group_by { |entry| entry.certificate.id }.transform_values { |list| list.map(&:name) }

        certificate_cells.map do |row, cell|
          certificate = cell.certificate
          PacketIndexPdf::Row.new(person: row.crew_member.sort_name, type: type_label(cell.certificate_type),
            number: certificate.certificate_number, completed_on: certificate.completed_on,
            expires_on: certificate.expires_on, status: cell.status,
            file_names: names_by_certificate.fetch(certificate.id, []))
        end
      end

      def index_gaps
        report.gaps.map do |gap|
          PacketIndexPdf::Gap.new(person: gap.crew_member.sort_name, type: type_label(gap.certificate_type),
            status: gap.status, expires_on: gap.certificate&.expires_on)
        end
      end

      def type_label(type)
        "#{type.code} - #{type.name}"
      end
  end
end
