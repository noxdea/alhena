# frozen_string_literal: true

require_relative "test_helper"

class VariationTest < Minitest::Test
  def test_axes_normalization_clamping_and_persistent_instances
    base = font("Roboto[wdth,wght].ttf")
    assert_equal %w[wght wdth], base.axes.keys
    assert_equal [0, 0], base.normalized_coordinates
    light = base.variation(wght: 100)
    heavy = base.variation(wght: 900)
    assert_equal [-1, 0], light.normalized_coordinates
    assert_equal [1, 0], heavy.normalized_coordinates
    assert_equal [1, 0], base.variation(wght: 2000).normalized_coordinates
    glyph = base.glyph_id("A")
    refute_equal light.outline(glyph).coordinates, heavy.outline(glyph).coordinates
    assert_equal [0, 0], base.normalized_coordinates
    refute_equal light.advance(glyph), heavy.advance(glyph)
    assert_raises(ArgumentError) { base.variation(wght: Float::NAN) }
    assert_raises(ArgumentError) { base.variation(XXXX: 0) }
  end

  def test_cff2_blends_and_default_instance
    base = font("SourceSerif4Variable-Roman.otf")
    glyph = base.glyph_id("A")
    refute_empty base.outline(glyph).coordinates
    refute_equal base.outline(glyph).coordinates, base.variation(wght: 900).outline(glyph).coordinates
    assert_equal base.advance(glyph), base.variation(wght: 400).advance(glyph)
  end
end
