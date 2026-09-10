# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "alhena"
require "timeout"

random = Random.new(12_345)
files = Dir[File.join(__dir__, "fonts", "*.{ttf,otf}")]
iterations = Integer(ENV.fetch("FUZZ_CASES", "2000"))
accepted = rejected = 0
iterations.times do |iteration|
  original = File.binread(files[iteration % files.length])
  bytes = original.dup
  if iteration.even?
    bytes = bytes.byteslice(0, random.rand(bytes.bytesize))
  else
    random.rand(1..8).times { bytes.setbyte(random.rand([bytes.bytesize, 4096].min), random.rand(256)) }
  end
  begin
    Timeout.timeout(2) do
      font = Alhena::Font.new(bytes)
      font.family
      font.glyph_id(65)
      font.rasterize(random.rand(font.glyph_count), size: 14) if font.glyph_count.positive?
    end
    accepted += 1
  rescue Alhena::Error, ArgumentError, EncodingError
    rejected += 1
  end
end
puts "#{iterations} seeded malformed fonts: #{accepted} accepted, #{rejected} rejected; no crashes or hangs"

10_000.times do
  program = Array.new(random.rand(1..128)) { random.rand(256) }.pack("C*")
  begin
    Alhena::CFF::Charstring.new([], [], default: 0, nominal: 0).outline(program)
  rescue Alhena::Error, ArgumentError
    # Rejection is expected; unexpected exceptions fail this executable check.
  end
end
puts "10,000 random CFF programs: no unexpected exceptions"
