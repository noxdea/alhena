# frozen_string_literal: true
require "alhena"
require "chunky_png"

font = Alhena::Font.open(ARGV.fetch(0))
text, size = ARGV.fetch(1, "Hello, Ruby!"), Integer(ARGV.fetch(2, "48"))
glyphs = text.codepoints.map { |code| font.glyph_id(code) }
width = glyphs.sum { |glyph| font.advance(glyph, size: size) }.ceil + 16
height = ((font.ascent - font.descent) * size.to_f / font.units_per_em).ceil + 16
baseline = (font.ascent * size.to_f / font.units_per_em).ceil + 8
image = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE)
x = 8.0
glyphs.each do |glyph|
  bitmap = font.rasterize(glyph, size: size, subpixel_x: x % 1)
  bitmap.coverage.each_byte.with_index do |value, i|
    col, row = x.floor + bitmap.left + i % bitmap.width, baseline - bitmap.top + i / bitmap.width
    image[col, row] = ChunkyPNG::Color.grayscale(255 - value) if col >= 0 && col < width && row >= 0 && row < height
  end
  x += font.advance(glyph, size: size)
end
image.save(ARGV.fetch(3, "text.png"))
