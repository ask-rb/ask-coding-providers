# frozen_string_literal: true

require_relative "test_helper"

class GemspecTest < Minitest::Test
  def test_gemspec_is_valid
    spec = Gem::Specification.load(File.expand_path("../ask-coding-providers.gemspec", __dir__))
    assert spec, "Could not load gemspec"
    assert_kind_of Gem::Specification, spec
    assert spec.name.to_s.start_with?("ask-")
    assert spec.version.to_s > "0"
  end
end
