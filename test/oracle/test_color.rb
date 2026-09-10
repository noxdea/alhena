# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/sfnt"
require "tempfile"
begin
  require_relative "../support/freetype"
  require "chunky_png"
rescue LoadError
end

class ColorOracleTest < Minitest::Test
  include SfntFixture

  def test_png_color_modes_filters_and_adam7_match_chunky_png
    skip "chunky_png unavailable" unless defined?(ChunkyPNG)
    image = ChunkyPNG::Image.new(9, 7)
    image.height.times do |y|
      image.width.times { |x| image[x, y] = [0xff0000ff, 0x00ff0080, 0x0000ff00, 0xffffffff][(x + y) % 4] }
    end
    [ChunkyPNG::COLOR_TRUECOLOR_ALPHA, ChunkyPNG::COLOR_INDEXED].each do |mode|
      [false, true].each do |interlace|
        (0..4).each do |filter|
          png = image.to_blob(color_mode: mode, interlace: interlace, filtering: filter)
          width, height, bytes = Alhena::PNG.decode(png)
          assert_equal [image.width, image.height], [width, height]
          assert_equal ChunkyPNG::Image.from_blob(png).pixels.pack("N*"), bytes
        end
      end
    end
  end

  def test_embedded_pixels_match_freetype_and_chunky_png
    skip "FreeType or chunky_png unavailable" unless defined?(FreeTypeOracle::Face) && defined?(ChunkyPNG)
    {"twemoji_smiley-sbix.ttf" => "😁", "NotoColorEmoji.ttf" => "😀"}.each do |name, character|
      face = font(name)
      glyph = face.glyph_id(character)
      embedded = face.embedded_bitmap(glyph, size: 109)
      decoded = ChunkyPNG::Image.from_blob(embedded.data)
      actual = face.color_bitmap(glyph, size: 109)
      assert_equal decoded.pixels.pack("N*"), actual.rgba
      FreeTypeOracle.with_face(font_path(name)) do |reference|
        expected = FreeTypeOracle.color_bitmap(reference, glyph, size: 109)
        assert_equal [expected.width, expected.height, expected.left, expected.top], [actual.width, actual.height, actual.left, actual.top]
        # FreeType stores premultiplied BGRA, losing low-alpha precision.
        expected.rgba.bytes.each_slice(4).zip(actual.rgba.bytes.each_slice(4)).each do |a, b|
          assert_equal a[3], b[3]
          3.times { |c| assert_in_delta a[c] * a[3] / 255.0, b[c] * b[3] / 255.0, 1.1 }
        end
      end
    end
  end

  def test_colr_layers_match_freetype
    skip "FreeType unavailable" unless defined?(FreeTypeOracle::Face)
    base = font
    colr = [0, 1, 14, 20, 2].pack("n2N2n") + [36, 0, 2, 36, 0, 37, 1].pack("n7")
    cpal = [0, 2, 1, 2, 14, 0].pack("n4Nn") + [0, 0, 255, 255, 255, 0, 0, 128].pack("C8")
    bytes = sfnt_with(base, "COLR" => colr, "CPAL" => cpal)
    Tempfile.create(["alhena-colr", ".ttf"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      actual = Alhena::Font.new(bytes).color_bitmap(36, size: 48)
      FreeTypeOracle.with_face(file.path) do |reference|
        expected = FreeTypeOracle.color_bitmap(reference, 36, size: 48)
        assert_equal [expected.width, expected.height, expected.left, expected.top], [actual.width, actual.height, actual.left, actual.top]
        difference = expected.rgba.bytes.zip(actual.rgba.bytes).sum { |a, b| (a - b).abs }.to_f / actual.rgba.bytesize
        assert_operator difference, :<=, 2
      end
    end
  end
end
