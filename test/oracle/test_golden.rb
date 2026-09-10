# frozen_string_literal: true

require_relative "../test_helper"
require "json"
begin
  require "chunky_png"
rescue LoadError
end

class GoldenTest < Minitest::Test
  def test_committed_freetype_pngs
    skip "chunky_png is not installed" unless defined?(ChunkyPNG)
    directory = File.expand_path("../golden", __dir__)
    JSON.parse(File.read(File.join(directory, "manifest.json"))).each do |entry|
      image = ChunkyPNG::Image.from_file(File.join(directory, entry.fetch("image")))
      expected = Alhena::Bitmap.new(width: image.width, height: image.height, left: entry.fetch("left"), top: entry.fetch("top"),
                                      coverage: image.pixels.map { |pixel| ChunkyPNG::Color.r(pixel) }.pack("C*"))
      actual = font(entry.fetch("font")).rasterize(entry.fetch("glyph"), size: entry.fetch("size"))
      assert_operator bitmap_error(expected, actual), :<=, 2.0, entry.fetch("image")
    end
  end
end
