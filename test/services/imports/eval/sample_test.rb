require "test_helper"
require_relative "eval_test_support"

class Imports::Eval::SampleTest < ActiveSupport::TestCase
  include EvalTestSupport

  test "discovers certificate files that have an expected answer and explains the rest" do
    with_samples_dir do |dir|
      write_sample(dir, "b_card", {})
      dir.join("a_photo.HEIC").binwrite("heic")
      dir.join("a_photo.expected.json").write('{"certificates":[]}')
      dir.join("c_scan.jpg").binwrite("jpg")
      dir.join("crew.zip").binwrite("zip")
      dir.join("letter.docx").binwrite("docx")
      dir.join(".keep").write("")
      dir.join("README.md").write("notes")
      dir.mkpath
      dir.join("nested").mkpath

      samples, skipped = Imports::Eval::Sample.discover(dir)

      assert_equal [ "a_photo.HEIC", "b_card.pdf" ], samples.map(&:name)
      assert_equal [ "image/heic", "application/pdf" ], samples.map(&:content_type)
      assert_equal [ "c_scan.jpg: no c_scan.expected.json beside it",
        "crew.zip: zip archives are not scored; unzip the files to include them",
        "letter.docx: not a PDF or image" ], skipped
    end
  end

  test "expected reads the answer file, and a bare array is the certificate list" do
    with_samples_dir do |dir|
      path = dir.join("card.pdf")
      path.binwrite("pdf")
      dir.join("card.expected.json").write('[{"pages":[1],"holder_name":"Li Chen"}]')

      sample = Imports::Eval::Sample.new(path, content_type: "application/pdf", expected_path: dir.join("card.expected.json"))

      assert_equal({ "certificates" => [ { "pages" => [ 1 ], "holder_name" => "Li Chen" } ] }, sample.expected)
    end
  end
end
