# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "test/"
  add_filter "version.rb"
  enable_coverage :branch
  minimum_coverage 70
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-agent/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-llm-providers/lib", __dir__)

require "ostruct"
require "ask-coding-providers"
require "minitest/autorun"
require "mocha/minitest"
require "vcr"

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path("../fixtures/vcr", __dir__)
  begin
    require "faraday"
    c.hook_into :faraday
  rescue LoadError
    # Faraday not available — VCR will still work for manual cassette usage
  end
  c.filter_sensitive_data("<OPENCODE_API_KEY>") { ENV["OPENCODE_API_KEY"] }
end
