module Imports
  module Eval
    # One accuracy-harness sample: a certificate file plus its hand-written correct answer,
    # <name>.expected.json beside it (the model output contract, docs/IMPORT_SPIKE.md).
    #
    #   samples, skipped = Imports::Eval::Sample.discover("test/fixtures/import_samples")
    #   samples.first.name      # => "ortiz_osha30.pdf"
    #   samples.first.expected  # => { "certificates" => [...], "non_certificate_pages" => [] }
    #   skipped                 # => ["crew.zip: zip archives are not scored ..."]
    class Sample
      CONTENT_TYPES = {
        ".pdf" => "application/pdf", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".png" => "image/png",
        ".webp" => "image/webp", ".heic" => "image/heic", ".heif" => "image/heif"
      }.freeze
      EXPECTED_SUFFIX = ".expected.json"
      IGNORED = /\A\.|\.(json|md|txt)\z/i # .keep, answer files, notes

      attr_reader :path, :content_type, :expected_path

      # [samples, skipped notes] for the files directly in dir, sorted by name.
      def self.discover(dir)
        samples = []
        skipped = []
        Pathname.new(dir).children.select(&:file?).sort.each do |path|
          name = path.basename.to_s
          next if name.match?(IGNORED)

          content_type = CONTENT_TYPES[path.extname.downcase]
          expected = path.sub_ext(EXPECTED_SUFFIX)
          if content_type.nil?
            skipped << "#{name}: #{path.extname.casecmp?(".zip") ? "zip archives are not scored; unzip the files to include them" : "not a PDF or image"}"
          elsif !expected.exist?
            skipped << "#{name}: no #{expected.basename} beside it"
          else
            samples << new(path, content_type: content_type, expected_path: expected)
          end
        end
        [ samples, skipped ]
      end

      def initialize(path, content_type:, expected_path:)
        @path = Pathname.new(path)
        @content_type = content_type
        @expected_path = Pathname.new(expected_path)
      end

      def name
        path.basename.to_s
      end

      # The parsed correct answer. Raises JSON::ParserError for a malformed file.
      def expected
        data = JSON.parse(expected_path.read)
        data.is_a?(Array) ? { "certificates" => data } : data
      end
    end
  end
end
