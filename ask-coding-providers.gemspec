# frozen_string_literal: true

require_relative "lib/ask/coding_providers/version"

Gem::Specification.new do |spec|
  spec.name = "ask-coding-providers"
  spec.version = Ask::CodingProviders::VERSION
  spec.authors = ["Kaka Ruto"]
  spec.email = ["kaka@myrrlabs.com"]

  spec.summary = "Coding agent adapters for the ask-rb ecosystem"
  spec.description = "Coding agent adapter interface and implementations (ACP, Codex, Claude, AskAgent) for the askoda ecosystem."
  spec.homepage = "https://github.com/ask-rb/ask-coding-providers"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mocha", "~> 3.1"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
