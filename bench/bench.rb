# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "alhena"

font_path = File.expand_path("../test/fonts/NotoSans-Regular.ttf", __dir__)
font = Alhena::Font.open(font_path)
glyph = font.glyph_id("A")
cache = Alhena::Cache.new
ascii = (32..126).map(&:chr).join
100.times { font.rasterize(glyph, size: 14) }
cache.rasterize(font, glyph, size: 14)
cid = Alhena::Font.open(File.expand_path("../test/fonts/SourceHanSansJP-Regular.otf", __dir__))
complex = cid.glyph_id("鬱")
cid.rasterize(complex, size: 48)

def measure(label, count, budget)
  times = 5.times.map do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count.times { yield }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000_000 / count
  end
  value = times.sort[2]
  puts "%s: %.2f us (budget %.2f us)" % [label, value, budget]
  abort "#{label} exceeds budget" if ARGV.include?("--assert") && value > budget
end

puts "#{RUBY_DESCRIPTION}; YJIT=#{RubyVM::YJIT.enabled?}"
measure("Font.open (Noto Sans, #{File.size(font_path)} bytes)", 100, 30_000) { Alhena::Font.open(font_path) }
measure("A 14px uncached", 1000, 500) { font.rasterize(glyph, size: 14) }
measure("A 14px cache hit", 100_000, 5) { cache.rasterize(font, glyph, size: 14) }
measure("95 ASCII prewarm", 20, 60_000) { Alhena::Cache.new.prewarm(font, ascii, 14) }
measure("CJK 鬱 48px uncached", 100, 3000) { cid.rasterize(complex, size: 48) }
before = GC.stat(:total_allocated_objects)
font.rasterize(glyph, size: 14)
puts "A 14px allocations: #{GC.stat(:total_allocated_objects) - before}"

# Compare the candidate accumulation buffers without retaining two runtime paths.
size, operations = 4096, 10_000
array = Array.new(size, 0.0)
packed = "\0".b * (size * 8)
measure("Array<Float> 10k updates", 50, Float::INFINITY) do
  operations.times { |i| array[i % size] += 0.125 }
end
measure("String/pack 10k updates", 50, Float::INFINITY) do
  operations.times do |i|
    at = i % size * 8
    packed[at, 8] = [packed.unpack1("d", offset: at) + 0.125].pack("d")
  end
end
