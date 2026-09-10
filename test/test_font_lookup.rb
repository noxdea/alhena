# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sfnt"

class FontLookupTest < Minitest::Test
  include SfntFixture

  def test_cmap_four_range_offsets_deltas_and_zero_glyphs_survive_cache_hits
    # A -> 35 + 1, B -> missing (not delta 1), C -> 37 + 1.
    subtable = [4, 38, 0, 4, 4, 1, 0, 0x43, 0xffff, 0, 0x41, 0xffff,
      1, 1, 4, 0, 35, 0, 37].pack("n*")
    parsed = Alhena::Font.new(sfnt_with(font, "cmap" => cmap_table(subtable)))
    3.times do
      assert_equal [36, 0, 38, 0, 0, 0], [65, 66, 67, 64, 68, 0x10000].map { |code| parsed.glyph_id(code) }
    end
    # Preserve the bounds check even after another scalar has populated cache.
    subtable = subtable.dup
    subtable[28, 2] = [0xfffe].pack("n")
    broken = Alhena::Font.new(sfnt_with(font, "cmap" => cmap_table(subtable)))
    assert_equal 0, broken.glyph_id(0x10000)
    2.times { assert_raises(Alhena::InvalidFont) { broken.glyph_id(65) } }
  end

  def test_lookup_caches_are_bounded_and_evicted_entries_recompute_correctly
    parsed = font("SourceHanSansJP-Regular.otf")
    expected = parsed.glyph_id("日")
    4200.times { |index| assert_equal 0, parsed.glyph_id(0x100000 + index) }
    assert_operator parsed.instance_variable_get(:@glyph_ids).length, :<=, 4096
    assert_equal expected, parsed.glyph_id("日")
    [false, true].each do |vertical|
      first = [parsed.advance(0, vertical: vertical), parsed.bearing(0, vertical: vertical)]
      4200.times { |glyph| parsed.advance(glyph, size: 14, vertical: vertical) }
      cache = parsed.instance_variable_get(vertical ? :@vertical_metrics : :@horizontal_metrics)
      assert_operator cache.length, :<=, 4096
      assert_equal first, [parsed.advance(0, vertical: vertical), parsed.bearing(0, vertical: vertical)]
      assert cache.values.all?(&:frozen?)
    end
  end

  def test_metric_cache_is_independent_of_size_direction_and_variation_instance
    parsed = font("SourceHanSansJP-Regular.otf")
    glyph = parsed.glyph_id("日")
    horizontal = parsed.__send__(:metric, glyph, vertical: false)
    vertical = parsed.__send__(:metric, glyph, vertical: true)
    3.times do
      [10, 24, 48].each do |size|
        assert_in_delta horizontal[0] * size.fdiv(parsed.units_per_em), parsed.advance(glyph, size: size)
        assert_in_delta horizontal[1] * size.fdiv(parsed.units_per_em), parsed.bearing(glyph, size: size)
        assert_in_delta vertical[0] * size.fdiv(parsed.units_per_em), parsed.advance(glyph, size: size, vertical: true)
        assert_in_delta vertical[1] * size.fdiv(parsed.units_per_em), parsed.bearing(glyph, size: size, vertical: true)
      end
    end
    variable = "Roboto[wdth,wght].ttf"
    normal = font(variable)
    bold = Alhena::Font.open(font_path(variable), axes: {wght: 900})
    [normal, bold].each do |face|
      id = face.glyph_id("A")
      reference = face.__send__(:metric, id)
      3.times do
        assert_equal reference[0], face.advance(id)
        assert_equal reference[1], face.bearing(id)
      end
    end
    refute_equal normal.advance(normal.glyph_id("A")), bold.advance(bold.glyph_id("A"))
  end

  def test_cached_metrics_do_not_bypass_argument_or_missing_table_validation
    parsed = font
    parsed.advance(36)
    [-1, 36.0, nil, "36", parsed.glyph_count].each do |invalid|
      assert_raises(ArgumentError) { parsed.advance(invalid) }
      assert_raises(ArgumentError) { parsed.bearing(invalid) }
    end
    [0, -1, Float::NAN, Float::INFINITY].each do |size|
      assert_raises(ArgumentError) { parsed.advance(36, size: size) }
    end
    assert_raises(Alhena::InvalidFont) { parsed.advance(36, vertical: true) }
    assert_equal 36, parsed.glyph_id("A")
    [-1, 0xd800, 0x110000, 65.0, nil, ""].each do |invalid|
      assert_raises(ArgumentError) { parsed.glyph_id(invalid) }
    end
  end

  def test_table_data_is_immutable_so_cached_decodes_cannot_become_stale
    parsed = font
    assert parsed.table("cmap").data.frozen?
    assert parsed.table("hmtx").data.frozen?
    assert_raises(FrozenError) { parsed.table("hmtx").data.setbyte(0, 0) }
  end

  def test_truncated_cmap_payloads_and_metric_tables_are_still_rejected
    [
      [0, 7, 0, 0].pack("n3C"),
      [6, 10, 0, 65, 1].pack("n5"),
      [12, 0, 16, 0, 1].pack("n2N3"),
      [13, 0, 16, 0, 1].pack("n2N3")
    ].each do |subtable|
      parsed = Alhena::Font.new(sfnt_with(font, "cmap" => cmap_table(subtable)))
      2.times { assert_raises(Alhena::InvalidFont) { parsed.glyph_id(65) } }
    end
    parsed = Alhena::Font.new(sfnt_with(font, "hmtx" => ""))
    2.times { assert_raises(Alhena::InvalidFont) { parsed.advance(36) } }
    hhea = font.table("hhea").data.dup
    hhea[34, 2] = [0].pack("n")
    parsed = Alhena::Font.new(sfnt_with(font, "hhea" => hhea))
    assert_raises(Alhena::InvalidFont) { parsed.advance(36) }
  end
end
