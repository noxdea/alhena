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

  def test_name_keyed_cff_font_is_really_subset_with_metrics_and_cmap_preserved
    source = font("SourceSans3-Regular.otf")
    glyph = source.glyph_id("A")
    bytes = Alhena::Subset.build(source, [glyph])
    subset = Alhena::Font.new(bytes)
    subset_glyph = subset.glyph_id("A")

    assert subset.cff?
    assert_operator subset.glyph_count, :<, source.glyph_count
    assert_equal 2, subset.glyph_count
    assert_equal source.outline(glyph).commands, subset.outline(subset_glyph).commands
    assert_in_delta source.advance_width(glyph), subset.advance_width(subset_glyph)
    assert_in_delta source.bearing(glyph), subset.bearing(subset_glyph)
    assert_equal source.cmap.filter_map { |codepoint, id| [codepoint, 1] if id == glyph }.to_h, subset.cmap
    assert_operator subset.table("CFF ").size, :<, source.table("CFF ").size
    assert_equal 0xb1b0afba, checksum(bytes)
  end

  def test_name_keyed_cff_can_be_repacked_as_cid_keyed_in_requested_order
    source = font("SourceSans3-Regular.otf")
    glyph = source.glyph_id("A")
    bytes = Alhena::Subset.build_cid(source, [0, glyph, glyph])
    subset = Alhena::CFF.new(Alhena::Binary.new(bytes))

    assert_equal source.outline(glyph).commands, subset.outline(1).commands
    assert_equal source.outline(glyph).commands, subset.outline(2).commands
    assert_operator bytes.bytesize, :<, source.table("CFF ").size
    assert_raises(ArgumentError) { Alhena::Subset.build_cid(source, [glyph]) }
  end

  def test_unsupported_cff_variants_are_rejected_instead_of_returning_the_source
    cff2 = font("SourceSerif4Variable-Roman.otf")
    cid = font("SourceHanSansJP-Regular.otf")

    assert_raises(Alhena::UnsupportedFont) { Alhena::Subset.build(cff2, [cff2.glyph_id("A")]) }
    assert_raises(Alhena::UnsupportedFont) { Alhena::Subset.build(cid, [cid.glyph_id("A")]) }
  end

  def test_subset_input_is_validated
    source = font("SourceSans3-Regular.otf")

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
