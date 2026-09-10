# frozen_string_literal: true

require_relative "../test_helper"
begin
  require "ttfunk"
rescue LoadError
end

class TTFunkTest < Minitest::Test
  def test_metrics_and_cmap_match
    skip "ttfunk is not installed" unless defined?(TTFunk)
    %w[Abel-Regular.ttf NotoSans-Regular.ttf SourceSans3-Regular.otf].each do |name|
      actual, expected = font(name), TTFunk::File.open(font_path(name))
      assert_equal expected.header.units_per_em, actual.units_per_em
      assert_equal expected.horizontal_header.ascent, actual.ascent
      assert_equal expected.horizontal_header.descent, actual.descent
      expected.cmap.unicode.each do |cmap|
        cmap.code_map.each { |code, glyph| assert_equal glyph, actual.glyph_id(code) }
      end
      actual.glyph_count.times do |glyph|
        assert_equal expected.horizontal_metrics.for(glyph).advance_width, actual.advance(glyph)
      end
    end
  end
end
