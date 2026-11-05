require "combine_pdf"

module Compliance
  # index.pdf for a compliance packet: a landscape table of the certificates in the zip
  # (with their file names), then the certificates left out of it and why (only when
  # there are any: those a person confirmed fake with the issuer), then the missing and
  # expired gaps. The packet goes to clients, so a confirmed fake one reads "Failed
  # verification with the issuer" (CLIENT_LABELS) and review flags are never mentioned.
  # Standard PDF fonts only cover Latin-1 poorly, so all text is transliterated to ASCII.
  #
  #   Compliance::PacketIndexPdf.new(project:, generated_at: Time.current, rows:, gaps:, excluded: [], summary:).render # => PDF bytes
  class PacketIndexPdf
    Row = Data.define(:person, :type, :number, :completed_on, :expires_on, :status, :file_names)
    Gap = Data.define(:person, :type, :status, :expires_on)
    Excluded = Data.define(:person, :type, :expires_on, :reason) # reason: "Failed verification with the issuer"

    PAGE_SIZE = [ 0, 0, 792, 612 ].freeze # US Letter, landscape
    MARGIN = 36
    FONT = :Helvetica
    BOLD = :"Helvetica-Bold"
    FONT_SIZE = 8
    LINE_HEIGHT = 11
    CELL_PADDING = 3
    MAX_FILE_LINES = 6
    SHADE = [ 0.95, 0.95, 0.95 ].freeze
    HEADER_SHADE = [ 0.86, 0.88, 0.91 ].freeze
    GRAY = [ 0.4, 0.4, 0.4 ].freeze
    # Client-facing wording for statuses whose Compliance label is internal.
    CLIENT_LABELS = { "fake" => "Failed verification with the issuer" }.freeze
    PUNCTUATION = { "\u2013" => "-", "\u2014" => "-", "\u00b7" => "-", "\u2018" => "'", "\u2019" => "'",
                    "\u201c" => '"', "\u201d" => '"' }.freeze

    # [heading, width in points, font size]; widths add up to the 720-point content width.
    ROW_COLUMNS = [
      [ "Person", 105, FONT_SIZE ], [ "Type", 130, FONT_SIZE ], [ "Number", 72, FONT_SIZE ], [ "Completed", 56, FONT_SIZE ],
      [ "Expires", 56, FONT_SIZE ], [ "Status", 76, FONT_SIZE ], [ "Files", 225, FONT_SIZE - 1 ]
    ].freeze
    GAP_COLUMNS = [ [ "Person", 200, FONT_SIZE ], [ "Type", 260, FONT_SIZE ], [ "Status", 130, FONT_SIZE ], [ "Expired on", 130, FONT_SIZE ] ].freeze
    EXCLUDED_COLUMNS = [ [ "Person", 200, FONT_SIZE ], [ "Type", 260, FONT_SIZE ], [ "Expires", 130, FONT_SIZE ], [ "Reason", 130, FONT_SIZE ] ].freeze

    def initialize(project:, rows:, gaps:, excluded: [], summary: nil, generated_at: Time.current)
      @project = project
      @rows = rows
      @gaps = gaps
      @excluded = excluded
      @summary = summary
      @generated_at = generated_at
    end

    def render
      @pdf = CombinePDF.new
      new_page
      draw_title
      draw_section("Certificates in this packet (#{@rows.size})", ROW_COLUMNS, @rows.map { |row| row_cells(row) },
        empty: @excluded.any? ? "No certificates in this packet." : "No current certificates on file for the required types.")
      if @excluded.any?
        draw_section("Left out of this packet (#{@excluded.size})", EXCLUDED_COLUMNS,
          @excluded.map { |excluded| excluded_cells(excluded) }, empty: nil)
      end
      # A left-out certificate is a gap too, so "everyone holds one" would be untrue then.
      draw_section("Missing and expired (#{@gaps.size})", GAP_COLUMNS, @gaps.map { |gap| gap_cells(gap) },
        empty: @excluded.any? ? "None besides the certificates left out above." : "None. Everyone holds a current certificate for each required type.")
      draw_footers
      @pdf.to_pdf
    end

    # ASCII-only text that the standard fonts can encode.
    def self.pdf_text(value)
      text = value.to_s.gsub(Regexp.union(PUNCTUATION.keys), PUNCTUATION)
      I18n.transliterate(text.unicode_normalize(:nfc).squish, replacement: "?").gsub(/[^\x20-\x7e]/, "").squish
    end

    private
      def content_width
        PAGE_SIZE[2] - (2 * MARGIN)
      end

      def new_page
        @page = @pdf.new_page(PAGE_SIZE)
        @y = PAGE_SIZE[3] - MARGIN
      end

      def draw_title
        title = [ @project.name, (@project.code.present? ? "(#{@project.code})" : nil) ].compact.join(" ")
        line("Compliance packet: #{title}", font: BOLD, size: 14, height: 20)

        details = [ @project.client, @project.location, project_dates ].compact_blank.join("  |  ")
        line(details, color: GRAY) if details.present?
        line("Generated #{@generated_at.in_time_zone(Time.zone).strftime("%b %-d, %Y %-l:%M %p %Z")} (America/Denver)", color: GRAY)
        line(summary_text, color: GRAY) if @summary
        @y -= LINE_HEIGHT
      end

      def project_dates
        return if @project.starts_on.blank? && @project.ends_on.blank?

        "#{format_date(@project.starts_on) || "?"} to #{format_date(@project.ends_on) || "open"}"
      end

      # Every status with its count, except a confirmed fake count of 0, which is left off.
      def summary_text
        Compliance::SEVERITY.filter_map do |status|
          count = @summary.fetch(status, 0)
          "#{status_label(status)}: #{count}" unless count.zero? && CLIENT_LABELS.key?(status)
        end.join("   ")
      end

      def status_label(status)
        CLIENT_LABELS.fetch(status.to_s) { Compliance.label(status) }
      end

      def line(text, font: FONT, size: FONT_SIZE + 1, height: LINE_HEIGHT + 2, color: [ 0, 0, 0 ])
        ensure_room(height)
        @y -= height
        text_at(text, x: MARGIN, width: content_width, height: height, font: font, size: size, color: color)
      end

      def draw_section(title, columns, cell_rows, empty:)
        ensure_room((LINE_HEIGHT * 4) + 6)
        @y -= 6
        line(title, font: BOLD, size: 10, height: 16)
        draw_header(columns)

        if cell_rows.empty?
          line(empty, color: GRAY, height: LINE_HEIGHT + 4)
        else
          cell_rows.each_with_index { |cells, index| draw_row(columns, cells, shaded: index.odd?) }
        end
      end

      def draw_header(columns)
        @y -= LINE_HEIGHT + 4
        box(y: @y, height: LINE_HEIGHT + 4, color: HEADER_SHADE)
        each_column(columns) do |(name, width), _, x|
          text_at(name, x: x, width: width, height: LINE_HEIGHT + 4, font: BOLD)
        end
      end

      # cells: one Array of lines per column.
      def draw_row(columns, cells, shaded:)
        height = (cells.map(&:size).max * LINE_HEIGHT) + 4
        if @y - height < MARGIN + LINE_HEIGHT
          new_page
          draw_header(columns)
        end

        @y -= height
        box(y: @y, height: height, color: SHADE) if shaded
        each_column(columns) do |(_, width, size), column_index, x|
          cells[column_index].each_with_index do |text, index|
            top = @y + height - 2 - ((index + 1) * LINE_HEIGHT)
            text_at(text, x: x, y: top, width: width, height: LINE_HEIGHT, size: size)
          end
        end
      end

      # Yields each column spec with its index and left edge.
      def each_column(columns)
        x = MARGIN
        columns.each_with_index do |column, index|
          yield column, index, x
          x += column[1]
        end
      end

      def row_cells(row)
        files = row.file_names.presence || [ "(no file on record)" ]
        if files.size > MAX_FILE_LINES
          files = files.first(MAX_FILE_LINES - 1) + [ "+ #{files.size - MAX_FILE_LINES + 1} more" ]
        end

        [ [ row.person ], [ row.type ], [ row.number.presence || "-" ], [ format_date(row.completed_on) || "-" ],
          [ format_date(row.expires_on) || "Never" ], [ status_label(row.status) ], files ]
      end

      def gap_cells(gap)
        [ [ gap.person ], [ gap.type ], [ status_label(gap.status) ], [ format_date(gap.expires_on) || "-" ] ]
      end

      def excluded_cells(excluded)
        [ [ excluded.person ], [ excluded.type ], [ format_date(excluded.expires_on) || "Never" ], [ excluded.reason ] ]
      end

      def ensure_room(height)
        new_page if @y - height < MARGIN + LINE_HEIGHT
      end

      def box(y:, height:, color:)
        @page.textbox("", x: MARGIN, y: y, width: content_width, height: height, box_color: color)
      end

      def text_at(text, x:, width:, height:, y: @y, font: FONT, size: FONT_SIZE, color: [ 0, 0, 0 ])
        inner_width = width - (2 * CELL_PADDING)
        text = fit(self.class.pdf_text(text), font, size, inner_width)
        return if text.empty?

        # A fixed baseline (not :center, which measures each string's glyphs) keeps a row's cells level.
        baseline = y + ((height - size) / 2.0) + 1
        @page.textbox(text, x: x + CELL_PADDING, y: baseline, width: inner_width, height: size, font: font,
          font_size: size, font_color: color, text_align: :left, text_valign: :bottom, text_padding: 0)
      end

      # Trims text with "..." until it fits width points.
      def fit(text, font, size, width)
        return text if text_width(text, font, size) <= width

        text = text[0...-1] while text.length > 1 && text_width("#{text}...", font, size) > width
        "#{text.rstrip}..."
      end

      def text_width(text, font, size)
        CombinePDF::Fonts.dimensions_of(text, [ font ], size).first
      end

      def draw_footers
        pages = @pdf.pages
        pages.each_with_index do |page, index|
          footer = "#{self.class.pdf_text(@project.display_name)}  |  Page #{index + 1} of #{pages.size}"
          page.textbox(footer, x: MARGIN, y: MARGIN - 20, width: content_width, height: 12, font: FONT,
            font_size: 7, font_color: GRAY, text_align: :right, text_valign: :center, text_padding: 0)
        end
      end

      def format_date(date)
        date&.strftime("%b %-d, %Y")
      end
  end
end
