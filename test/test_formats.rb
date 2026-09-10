# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sfnt"

class FormatTest < Minitest::Test
  include SfntFixture

  def test_cmap_0_6_12_13_and_missing_characters
    source = font
    bytes = Array.new(256, 0)
    bytes[65] = 36
    format0 = [0, 262, 0].pack("n3") + bytes.pack("C*")
    format6 = [6, 14, 0, 65, 2, 36, 37].pack("n7")
    [format0, format6].each do |subtable|
      parsed = Alhena::Font.new(sfnt_with(source, "cmap" => cmap_table(subtable)))
      assert_equal 36, parsed.glyph_id(65)
      assert_equal 0, parsed.glyph_id(0x10000)
    end
    [12, 13].each do |format|
      subtable = [format, 0, 28, 0, 1, 0x1f600, 0x1f601, 36].pack("n2N6")
      parsed = Alhena::Font.new(sfnt_with(source, "cmap" => cmap_table(subtable)))
      assert_equal 36, parsed.glyph_id(0x1f600)
      assert_equal format == 12 ? 37 : 36, parsed.glyph_id(0x1f601)
      assert_equal 0, parsed.glyph_id(0x1f602)
    end
  end

  def test_cmap_variation_default_nondefault_and_unsupported
    source = font
    # One UVS record: default A, non-default B -> glyph 99.
    variation = [14, 38, 1].pack("nN2") + [0xfe, 0x0f].pack("nC") + [21, 29].pack("N2")
    variation << [1].pack("N") << "\x00\x00\x41\x00" << [1].pack("N") << "\x00\x00\x42" << [99].pack("n")
    bmp = [6, 14, 0, 65, 2, 36, 37].pack("n7")
    cmap = [0, 2, 0, 5, 20, 0, 3, 20 + variation.bytesize].pack("n4Nn2N") + variation + bmp
    parsed = Alhena::Font.new(sfnt_with(source, "cmap" => cmap))
    assert_equal 36, parsed.glyph_id("A", variation_selector: 0xfe0f)
    assert_equal 99, parsed.glyph_id("B", variation_selector: 0xfe0f)
    assert_equal 0, parsed.glyph_id("C", variation_selector: 0xfe0f)
    assert_equal 0, parsed.glyph_id("A", variation_selector: 0xfe0e)
    3.times do
      assert_equal 36, parsed.glyph_id("A")
      assert_equal 37, parsed.glyph_id("B")
      assert_equal 36, parsed.glyph_id("A", variation_selector: "\ufe0f")
      assert_equal 99, parsed.glyph_id("B", variation_selector: "\ufe0f")
      assert_equal 0, parsed.glyph_id("C", variation_selector: 0xfe0f)
    end
  end

  def test_ttc_indexes_and_absolute_table_offsets
    bytes = File.binread(font_path)
    count = bytes.unpack1("n", offset: 4)
    count.times do |i|
      at = 12 + i * 16 + 8
      bytes[at, 4] = [bytes.unpack1("N", offset: at) + 20].pack("N")
    end
    collection = "ttcf" + [0x10000, 2, 20, 20].pack("N4") + bytes
    assert_equal "Abel", Alhena::Font.new(collection, index: 0).family
    assert_equal 36, Alhena::Font.new(collection, index: 1).glyph_id("A")
    assert_raises(Alhena::InvalidFont) { Alhena::Font.new(collection, index: 2) }
  end

  def test_composite_cycle_and_glyph_offset_bounds
    source = font("NotoSans-Regular.ttf")
    glyph = source.glyph_id("é")
    short = source.table("head").i16(50).zero?
    offset = short ? source.table("loca").u16(glyph * 2) * 2 : source.table("loca").u32(glyph * 4)
    glyf = source.table("glyf").data.dup
    assert_operator glyf.unpack1("s>", offset: offset), :<, 0
    glyf[offset + 12, 2] = [glyph].pack("n")
    parsed = Alhena::Font.new(sfnt_with(source, "glyf" => glyf))
    assert_raises(Alhena::InvalidFont) { parsed.outline(glyph) }
    loca = source.table("loca").data.dup
    loca[0, short ? 2 : 4] = short ? [65535].pack("n") : [0xffffffff].pack("N")
    parsed = Alhena::Font.new(sfnt_with(source, "loca" => loca))
    assert_raises(Alhena::InvalidFont) { parsed.outline(0) }
  end

  def test_hmtx_reuses_last_advance_and_reads_trailing_bearings
    source = font
    hhea = source.table("hhea").data.dup
    hhea[34, 2] = [1].pack("n")
    metrics = [1000, 10, *Array.new(source.glyph_count - 1) { |i| i + 20 }].pack("n*")
    parsed = Alhena::Font.new(sfnt_with(source, "hhea" => hhea, "hmtx" => metrics))
    assert_equal 1000, parsed.advance(25)
    assert_equal 44, parsed.bearing(25)
  end
end
