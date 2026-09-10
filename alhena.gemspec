# frozen_string_literal: true

require_relative "lib/alhena/version"

Gem::Specification.new do |spec|
  spec.name = "alhena"
  spec.version = Alhena::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "Pure Ruby TrueType and CFF font rasterization"
  spec.description = "Read sfnt and TTC fonts, extract outlines, and produce antialiased grayscale or LCD glyph bitmaps without native dependencies."
  spec.homepage = "https://github.com/noxdea/alhena"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "examples/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
end
