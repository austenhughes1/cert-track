require "support/import_samples"

# Synthetic accuracy-harness samples in a temp dir: a PDF per certificate spec plus the
# matching <name>.expected.json. Every name and number is made up.
module EvalTestSupport
  TYPE_CODES = { "Flagger Certification" => "FLAGGER", "Adult First Aid CPR AED" => "FIRSTAID" }.freeze

  def with_samples_dir
    Dir.mktmpdir("certtrack-eval") { |dir| yield Pathname.new(dir) }
  end

  # Writes name.pdf from page specs (see ImportSamples.pdf) and name.expected.json from
  # expected (default: what the synthetic pages say). Returns the PDF path.
  def write_sample(dir, name, *pages, expected: nil)
    path = dir.join("#{name}.pdf")
    path.binwrite(ImportSamples.pdf(*pages))
    expected ||= expected_for(pages)
    dir.join("#{name}.expected.json").write(JSON.pretty_generate(expected))
    path
  end

  def expected_for(pages)
    certificates = []
    non_certificate_pages = []
    pages.each_with_index do |page, index|
      next non_certificate_pages << index + 1 unless page.is_a?(Hash)

      fields = ImportSamples.certificate(**page)
      certificates << {
        "pages" => [ index + 1 ], "holder_name" => fields[:holder],
        "certificate_type_code" => TYPE_CODES.fetch(fields[:name], "OSHA30"), "certificate_name_as_printed" => fields[:name],
        "issuer" => fields[:issuer], "certificate_number" => fields[:number], "completed_on" => fields[:completed],
        "expires_on" => fields[:expires], "confidence" => 1, "notes" => nil
      }
    end
    { "certificates" => certificates, "non_certificate_pages" => non_certificate_pages }
  end
end
