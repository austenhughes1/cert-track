require "combine_pdf"

module Imports
  # Gives each certificate the AI found in one uploaded file its own import item.
  #
  #   parts = Imports::Splitter.new(item).call(item.extraction["certificates"])
  #   parts.map { |part| [ part.item.page_range, part.certificate["holder_name"] ] }
  #   # => [["1", "Juan A. Ortiz"], ["2-3", "Li Chen"]]
  #
  # The first certificate stays on item; each further one becomes a new ImportItem in the
  # same batch with the same sha256 and original_filename, source_item: item, its own pages'
  # extracted_text and an extraction holding just its certificate. Run it inside a
  # transaction (Imports::ProcessExtractionJob does): new files upload when that commits,
  # and reloading item before then would drop its replaced file.
  #
  # PDFs: a certificate's pages ("pages" => [2, 3]) become page_range "2-3" (the span from the
  # first to the last page listed; pages outside the file are ignored, none listed means the
  # whole file). When the span is shorter than the file, those pages are cut out with
  # combine_pdf into "<name> p2-3.pdf" and attached in place of the whole file, and the
  # item's extracted_text is cut to the same pages. If combine_pdf can't read the PDF (an
  # error, or a stack overflow on a deeply nested object), every item keeps the whole file
  # (logged); a storage error while downloading it is raised.
  # Images are never split: page_range stays nil and every item shares the one image.
  #
  # QR codes (Phase 3b): each PDF item gets the file's barcodes that are on its own pages,
  # numbered as in its own file: a part cut out as pages 3-4 has them on pages 1-2, and a part
  # that kept the whole file keeps the file's numbers. Every item of an image shares its barcodes.
  class Splitter
    Part = Data.define(:item, :certificate)

    PDF_CONTENT_TYPE = "application/pdf".freeze
    PAGE_MARKER = /^=== page (\d+) ===[ \t]*\n?/

    class << self
      # "3" for [3], "1-2" for [1, 2].
      def page_range_for(pages)
        first, last = pages.minmax
        first == last ? first.to_s : "#{first}-#{last}"
      end

      # A new PDF (bytes) holding the given 1-indexed pages of a parsed CombinePDF document.
      def extract_pages(pdf, pages)
        output = CombinePDF.new
        pages.each { |number| output << pdf.pages.fetch(number - 1) }
        output.to_pdf
      end

      # "ortiz p1-2.pdf" for "crew.zip/cards/ortiz.pdf" and "1-2".
      def split_filename(original_filename, page_range)
        base = File.basename(original_filename.to_s.split("/").last.to_s, ".*").presence || "certificate"
        "#{base} p#{page_range}.pdf"
      end

      # { 1 => "page one text", 2 => "..." } from text with "=== page N ===" markers; {} without markers.
      def page_texts(text)
        parts = text.to_s.split(PAGE_MARKER)
        parts.shift # anything before the first marker
        parts.each_slice(2).to_h { |number, body| [ number.to_i, body.to_s.sub(/\s+\z/, "") ] }
      end

      # The marked text of just these pages; the whole text when it has no page markers.
      def text_for_pages(text, pages)
        texts = page_texts(text)
        return text if texts.empty?

        pages.filter_map { |number| "=== page #{number} ===\n#{texts[number]}" if texts.key?(number) }.join("\n").presence
      end
    end

    def initialize(item)
      @item = item
    end

    # certificates: the model's certificate hashes (string keys), in order. Returns one Part per certificate.
    def call(certificates)
      certificates = Array(certificates)
      return [] if certificates.empty?

      # Taken before item's own file and text are narrowed to its pages.
      @original_blob = item.file.blob if item.file.attached?
      @pdf = @original_blob&.content_type == PDF_CONTENT_TYPE
      @full_text = item.extracted_text
      @full_barcodes = Array(item.barcodes).select { |barcode| barcode.is_a?(Hash) }.map(&:stringify_keys)
      load_document
      certificates.each_with_index.map do |certificate, index|
        pages = pages_for(certificate)
        target = index.zero? ? narrow_original(pages) : create_split_item(certificate, pages)
        Part.new(item: target, certificate:)
      end
    end

    private
      attr_reader :item

      def pdf?
        @pdf
      end

      # A storage error while downloading is raised (the job retries); a PDF combine_pdf can't
      # read leaves @document nil.
      def load_document
        @document = nil
        return unless pdf?

        data = @original_blob.download
        @document = unsplittable("can't read the PDF") do
          CombinePDF.parse(data).tap { |document| raise CombinePDF::ParsingError, "no pages found" if document.pages.empty? }
        end
      end

      # The block's value, or nil (logged) when combine_pdf fails on this file. combine_pdf
      # parses recursively, so a deeply nested object (which poppler reads fine) overflows the
      # stack: SystemStackError is not a StandardError, and must not escape the pipeline.
      def unsplittable(what)
        yield
      rescue StandardError, SystemStackError => error
        Rails.logger.warn("[Imports::Splitter] import item #{item.id}: #{what}, keeping the whole file (#{error.class}: #{error.message})")
        nil
      end

      def page_count
        @page_count ||=
          if @document then @document.pages.size
          elsif pdf? then [ self.class.page_texts(@full_text).keys.max.to_i, 1 ].max
          else 1
          end
      end

      # The span of listed pages within the file, or every page when none are usable.
      def pages_for(certificate)
        listed = Array(certificate["pages"]).filter_map { |page| Integer(page, exception: false) }.select { |page| page.between?(1, page_count) }
        listed.empty? ? (1..page_count).to_a : (listed.min..listed.max).to_a
      end

      def partial?(pages)
        pdf? && pages.size < page_count
      end

      def narrow_original(pages)
        split = nil
        item.page_range = self.class.page_range_for(pages) if pdf?
        if partial?(pages)
          item.extracted_text = self.class.text_for_pages(@full_text, pages)
          split = split_attachable(pages)
          item.file = split if split
        end
        item.barcodes = barcodes_for(pages, cut: split.present?) if pdf?
        item.save!
        item
      end

      def create_split_item(certificate, pages)
        page_range = self.class.page_range_for(pages) if pdf?
        text = partial?(pages) ? self.class.text_for_pages(@full_text, pages) : @full_text
        split = split_attachable(pages) if partial?(pages)

        ImportItem.create!(
          import_batch: item.import_batch, source_item: item, status: item.status,
          sha256: item.sha256, original_filename: item.original_filename, page_range:,
          extracted_text: text, extraction: { "certificates" => [ certificate ], "non_certificate_pages" => [] },
          provider: item.provider, ai_units_used: 0, file: split || @original_blob,
          barcodes: pdf? ? barcodes_for(pages, cut: split.present?) : @full_barcodes
        )
      end

      # The file's barcodes on these pages; renumbered from 1 when the pages were cut into their own file.
      def barcodes_for(pages, cut:)
        offset = cut ? pages.first - 1 : 0
        @full_barcodes.filter_map do |barcode|
          page = Integer(barcode["page"].to_s, exception: false)
          barcode.merge("page" => page - offset) if page && pages.include?(page)
        end
      end

      # An attachable for the cut-out pages, or nil when the PDF can't be split.
      def split_attachable(pages)
        return unless @document

        page_range = self.class.page_range_for(pages)
        bytes = unsplittable("can't cut out pages #{page_range}") { self.class.extract_pages(@document, pages) }
        return unless bytes

        { io: StringIO.new(bytes),
          filename: self.class.split_filename(item.original_filename.presence || @original_blob.filename.to_s, page_range),
          content_type: PDF_CONTENT_TYPE, identify: false }
      end
  end
end
