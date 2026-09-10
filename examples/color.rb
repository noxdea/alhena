# frozen_string_literal: true

require "alhena"
require "chunky_png"

font = Alhena::Font.open(ARGV.fetch(0))
glyph = font.glyph_id(ARGV.fetch(1, "😀"))
bitmap = font.color_bitmap(glyph, size: Integer(ARGV.fetch(2, "64")))
abort "The glyph has no supported color image" unless bitmap
image = ChunkyPNG::Image.new(bitmap.width, bitmap.height, bitmap.rgba.unpack("N*"))
image.save(ARGV.fetch(3, "color.png"))
