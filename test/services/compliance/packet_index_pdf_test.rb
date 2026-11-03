require "test_helper"

class Compliance::PacketIndexPdfTest < ActiveSupport::TestCase
  Row = Compliance::PacketIndexPdf::Row
  Gap = Compliance::PacketIndexPdf::Gap

  setup do
    @project = projects(:tower_2417)
    @summary = { "missing" => 3, "expired" => 2, "expiring" => 2, "lapses_on_project" => 1, "valid" => 8 }
  end

  test "renders a parseable PDF listing the project, certificates and gaps" do
    rows = [
      Row.new(person: "García, María", type: "FLAGGER - Flagger", number: "FL-55501", completed_on: Date.new(2026, 1, 5),
        expires_on: Date.new(2029, 1, 5), status: "valid", file_names: [ "Garcia_Maria - FLAGGER - exp 2029-01-05.pdf", "Garcia_Maria - FLAGGER - exp 2029-01-05 (2).jpg" ]),
      Row.new(person: "Ortiz, Juan", type: "OSHA30 - OSHA 30", number: nil, completed_on: Date.new(2024, 12, 1),
        expires_on: nil, status: "valid", file_names: [])
    ]
    gaps = [ Gap.new(person: "Miller, David", type: "FIRSTAID - First Aid", status: "missing", expires_on: nil) ]

    data = render_pdf(rows: rows, gaps: gaps, generated_at: Time.zone.local(2026, 11, 2, 15, 4))
    pdf = CombinePDF.parse(data)
    text = pdf_strings(data)

    assert_equal 1, pdf.pages.size
    assert_includes text, "Compliance packet: Tower 2417 Upgrade (2417)"
    assert(text.any? { |line| line.start_with?("Generated Nov 2, 2026 3:04 PM") })
    assert_includes text, "Garcia, Maria" # transliterated for the standard fonts
    assert_includes text, "Garcia_Maria - FLAGGER - exp 2029-01-05 (2).jpg"
    assert_includes text, "FL-55501"
    assert_includes text, "Jan 5, 2029"
    assert_includes text, "Never"
    assert_includes text, "(no file on record)"
    assert_includes text, "Missing and expired (1)"
    assert_includes text, "Miller, David"
    assert_includes text, "Missing"
    assert(text.any? { |line| line.include?("Expired: 2") && line.include?("Missing: 3") })
  end

  test "paginates long lists and numbers every page" do
    rows = Array.new(120) do |index|
      Row.new(person: "Person #{index}, Test", type: "OSHA30 - OSHA 30", number: "N#{index}", completed_on: Date.new(2026, 1, 1),
        expires_on: Date.new(2027, 1, 1), status: "valid", file_names: [ "file #{index}.pdf" ])
    end
    gaps = Array.new(40) { |index| Gap.new(person: "Gap #{index}, Test", type: "FLAGGER - Flagger", status: "expired", expires_on: Date.new(2026, 1, 1)) }

    data = render_pdf(rows: rows, gaps: gaps)
    pages = CombinePDF.parse(data).pages
    text = pdf_strings(data)

    assert_operator pages.size, :>, 2
    pages.size.times { |index| assert(text.any? { |line| line.end_with?("Page #{index + 1} of #{pages.size}") }) }
    assert_includes text, "Person 119, Test"
    assert_includes text, "Gap 39, Test"
    assert_operator text.count("Person"), :>=, pages.size - 1, "the table header repeats on each page"
  end

  test "renders empty sections" do
    data = render_pdf(rows: [], gaps: [], summary: nil)
    text = pdf_strings(data)

    assert_equal 1, CombinePDF.parse(data).pages.size
    assert_includes text, "No current certificates on file for the required types."
    assert_includes text, "None. Everyone holds a current certificate for each required type."
  end

  test "truncates text that overflows its column and caps long file lists" do
    rows = [ Row.new(person: "A" * 200, type: "T", number: nil, completed_on: nil, expires_on: nil, status: "expired",
      file_names: Array.new(10) { |index| "file-#{index}.pdf" }) ]

    text = pdf_strings(render_pdf(rows: rows, gaps: []))

    assert(text.any? { |line| line.start_with?("AAAA") && line.end_with?("...") && line.length < 200 })
    assert_includes text, "+ 5 more"
    assert_not_includes text, "file-9.pdf"
  end

  test "pdf_text transliterates to printable ASCII" do
    assert_equal "2417 - Nunez - O'Brien \"Lopez\"", Compliance::PacketIndexPdf.pdf_text("2417 · Núñez — O’Brien “López”")
    assert_equal "tab and newline", Compliance::PacketIndexPdf.pdf_text("tab\tand\nnewline")
    assert_equal "", Compliance::PacketIndexPdf.pdf_text(nil)
  end

  private
    def render_pdf(rows:, gaps:, summary: @summary, generated_at: Time.current)
      Compliance::PacketIndexPdf.new(project: @project, rows: rows, gaps: gaps, summary: summary, generated_at: generated_at).render
    end

    # combine_pdf writes each text run as a hex string: <...> Tj
    def pdf_strings(data)
      data.scan(/<([0-9a-fA-F]+)> Tj/).map { |(hex)| [ hex ].pack("H*") }
    end
end
