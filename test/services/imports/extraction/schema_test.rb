require "test_helper"

class Imports::Extraction::SchemaTest < ActiveSupport::TestCase
  CERTIFICATE = Imports::Extraction::Schema::CERTIFICATE

  test "every certificate property is required, and the prompt's example has exactly those keys" do
    properties = CERTIFICATE[:properties].keys.map(&:to_s)
    example = JSON.parse(Imports::Extraction::Schema::EXAMPLE)

    assert_equal properties.sort, CERTIFICATE[:required].sort
    assert_equal properties.sort, example["certificates"].sole.keys.sort
    assert_empty Imports::Extraction::Schema::FIELDS - properties
  end

  test "the Phase 3b fields are nullable strings" do
    %i[certificate_issuer_code verification_code verification_url].each do |field|
      assert_equal %w[string null], CERTIFICATE[:properties].fetch(field)[:type], field
      assert_includes Imports::Extraction::Schema::FIELDS, field.to_s
    end
  end
end
