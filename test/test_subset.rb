# frozen_string_literal: true

require_relative "test_helper"

class SubsetTest < Minitest::Test
  def test_true_type_subset_keeps_requested_glyphs_and_composite_dependencies
    source = font("NotoSans-Regular.ttf")
    glyph = source.glyph_id("é")
    subset = Alhena::Font.new(Alhena::Subset.build(source, [glyph]))

    assert_operator subset.glyph_count, :<, source.glyph_count
    assert_equal [glyph], source.glyph_ids("é")
    assert_equal "é".ord, subset.unicode_for_glyph(subset.glyph_id("é"))
    assert_equal source.outline(glyph).commands, subset.outline(subset.glyph_id("é")).commands
    assert_in_delta source.advance_width(glyph), subset.advance_width(subset.glyph_id("é"))
    assert_equal source.bbox, subset.bbox
    assert_equal 0xb1b0afba, checksum(subset.data)
  end

  def test_cff_font_remains_valid_and_input_is_validated
    source = font("SourceSans3-Regular.otf")
    subset = Alhena::Font.new(Alhena::Subset.build(source, [source.glyph_id("A")]))

    assert subset.cff?
    assert_equal source.glyph_count, subset.glyph_count
    assert_equal source.glyph_id("A"), subset.glyph_id("A")
    assert_raises(ArgumentError) { Alhena::Subset.build(source, [source.glyph_count]) }
    assert_raises(ArgumentError) { Alhena::Subset.build(Object.new, []) }
  end

  private

  def checksum(data)
    padded = data.dup
    padded << "\0" until padded.bytesize % 4 == 0
    padded.unpack("N*").sum & 0xffffffff
  end
end
