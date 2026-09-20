# frozen_string_literal: true

require "fileutils"
require "alhena"
require_relative "png_helper"

font = Alhena::Font.open(File.expand_path("../test/fonts/Abel-Regular.ttf", __dir__))
glyphs = %w[A g]
width = 720
height = 360
rgba = [18, 23, 31, 255] * width * height
glyphs.each_with_index do |character, index|
  bitmap = font.rasterize(font.glyph_id(character), size: 180)
  x = 150 + index * 210
  y = 70
  bitmap.height.times do |row|
    bitmap.width.times do |column|
      alpha = bitmap.coverage.getbyte(row * bitmap.width + column)
      rgba[((y + row) * width + x + column) * 4, 4] = [95, 218, 195, alpha]
    end
  end
end
FileUtils.mkdir_p("docs/media")
DemoPNG.write("docs/media/screenshot.png", width, height, rgba.pack("C*"))
