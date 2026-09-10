# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "alhena"
require "chunky_png"
require "json"
require "fileutils"
require_relative "../test/support/freetype"

directory = File.expand_path("../test/golden", __dir__)
FileUtils.mkdir_p(directory)
manifest = []
%w[DejaVuSans.ttf NotoSans-Regular.ttf SourceSans3-Regular.otf SourceHanSansJP-Regular.otf].each do |name|
  path = File.expand_path("../test/fonts/#{name}", __dir__)
  font = Alhena::Font.open(path)
  FreeTypeOracle.with_face(path) do |face|
    [14, 24, 48].each do |size|
      character = name.start_with?("SourceHan") ? "鬱" : "S"
      glyph = font.glyph_id(character)
      bitmap = FreeTypeOracle.rasterize(face, glyph, size: size)
      filename = "#{File.basename(name, '.*')}-#{size}.png"
      image = ChunkyPNG::Image.new(bitmap.width, bitmap.height)
      bitmap.coverage.each_byte.with_index { |c, i| image[i % bitmap.width, i / bitmap.width] = ChunkyPNG::Color.grayscale(c) }
      image.save(File.join(directory, filename))
      manifest << {font: name, size: size, glyph: glyph, image: filename, left: bitmap.left, top: bitmap.top}
    end
  end
end
File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
puts "Wrote #{manifest.length} FreeType reference PNGs"
