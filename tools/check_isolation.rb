# frozen_string_literal: true

require "ripper"
root = File.expand_path("..", __dir__)
Dir[File.join(root, "lib", "**", "*.rb")].each do |file|
  constants = Ripper.lex(File.read(file)).filter_map { |_, type, text, _| text if type == :on_const }
  forbidden = constants & %w[Canopus Zaniah Quire Tessera]
  abort "#{file}: application dependency #{forbidden.join(', ')}" unless forbidden.empty?
end
spec = Gem::Specification.load(File.join(root, "alhena.gemspec"))
abort "runtime gem dependencies are forbidden" unless spec.runtime_dependencies.empty?
puts "Standalone package: no application references or runtime gem dependencies"
