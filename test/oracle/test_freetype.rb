# frozen_string_literal: true

require_relative "../test_helper"
begin
  require_relative "../support/freetype"
rescue LoadError
  # The native library is optional; CI installs it for the oracle job.
end

class FreeTypeTest < Minitest::Test
  def setup
    skip "FreeType is not installed" unless defined?(FreeTypeOracle::Face)
  end

  def test_grayscale_matches_freetype
    files = %w[Abel-Regular.ttf NotoSans-Regular.ttf SourceSans3-Regular.otf SourceHanSansJP-Regular.otf]
    files << "DejaVuSans.ttf" if File.file?(font_path("DejaVuSans.ttf"))
    worst = [0, nil]
    files.each do |name|
      face = font(name)
      characters = (32..126).to_a
      characters.concat("éÅøﬁ日本語あいう漢字龍鬱".codepoints.select { |code| face.glyph_id(code) != 0 })
      FreeTypeOracle.with_face(font_path(name)) do |reference|
        characters.each do |code|
          assert_equal FreeTypeOracle.FT_Get_Char_Index(reference, code), face.glyph_id(code)
          [10, 14, 24, 48].each do |size|
            glyph = face.glyph_id(code)
            expected = FreeTypeOracle.rasterize(reference, glyph, size: size)
            actual = face.rasterize(glyph, size: size)
            error = bitmap_error(expected, actual)
            detail = "#{name} U+#{code.to_s(16)} #{size}px MAE #{error}"
            worst = [error, detail] if error > worst[0]
            assert_operator error, :<=, 2.0, detail
          end
        end
        [0.25, 0.5, 0.75].each do |offset|
          expected = FreeTypeOracle.rasterize(reference, face.glyph_id("S"), size: 24, subpixel_x: offset)
          assert_operator bitmap_error(expected, face.rasterize(face.glyph_id("S"), size: 24, subpixel_x: offset)), :<=, 2.0
        end
      end
    end
    puts "FreeType worst glyph: #{worst.last}"
  end
end
