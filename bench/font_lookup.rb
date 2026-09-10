# frozen_string_literal: true

require "json"
if ARGV.include?("--ui")
  require_relative "../../zaniah/lib/zaniah"
else
  require_relative "../lib/alhena"
end
puts JSON.generate(ruby: RUBY_DESCRIPTION, font_implementation: Alhena::Font.instance_method(:glyph_id).source_location.first)

def sample(name, count, &operation)
  5_000.times { |index| operation.call(index) }
  measurements = Array.new(5) do
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count.times { |index| operation.call(index) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    [(elapsed * 1000).round(3), ((GC.stat(:total_allocated_objects) - allocated).fdiv(count)).round(4)]
  end
  puts JSON.generate(name: name, calls: count, median_ms: measurements.map(&:first).sort[2],
    objects_per_call: measurements.map(&:last).sort[2])
end

font = Alhena::Font.open(File.expand_path("../test/fonts/Abel-Regular.ttf", __dir__))
cjk = Alhena::Font.open(File.expand_path("../test/fonts/SourceHanSansJP-Regular.otf", __dir__))
variable = Alhena::Font.open(File.expand_path("../test/fonts/Roboto[wdth,wght].ttf", __dir__), axes: {wght: 900})
latin = (32..126).to_a
codes = "日本語あいう漢字龍鬱".codepoints
glyph = variable.glyph_id("A")
sample("latin_cmap", 100_000) { |index| font.glyph_id(latin[index % latin.length]) }
sample("cjk_cmap", 100_000) { |index| cjk.glyph_id(codes[index % codes.length]) }
sample("missing_cmap", 100_000) { font.glyph_id(0x10ffff) }
sample("advance", 100_000) { font.advance(36, size: 14) }
sample("bearing", 100_000) { font.bearing(36, size: 14) }
sample("variable_advance", 100_000) { variable.advance(glyph, size: 14) }

# Optional integration measurement using the sibling UI's vendored Alhena:
# refresh its vendor pin first. Capacity 1 forces actual layout misses.
if ARGV.include?("--ui")
  typesetter = Zaniah::TextSystem::Typesetter.new(font: font, capacity: 1)
  lines = Array.new(1_000) { |index| "class Example#{index}; value = \"Hello world\"; end" }
  sample("ui_layout_miss", 1_000) { |index| typesetter.layout_line(lines[index % lines.length], size: 14) }
end
