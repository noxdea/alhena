# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sfnt"
require "zlib"

class ColorTest < Minitest::Test
  include SfntFixture

  def test_embedded_sbix_and_cbdt
    {"twemoji_smiley-sbix.ttf" => "😁", "NotoColorEmoji.ttf" => "😀"}.each do |name, character|
      face = font(name)
      glyph = face.glyph_id(character)
      embedded = face.embedded_bitmap(glyph, size: 48)
      assert_equal :png, embedded.format
      assert_equal 109, embedded.ppem
      bitmap = face.color_bitmap(glyph, size: 48)
      assert_operator bitmap.width, :>, 0
      assert_equal bitmap.width * bitmap.height * 4, bitmap.rgba.bytesize
      assert bitmap.rgba.frozen?
      assert_equal bitmap.to_bitmap.coverage, face.rasterize(glyph, size: 48).coverage
      assert_nil face.embedded_bitmap(face.glyph_id(" "), size: 48)
    end
  end

  def colr_font
    base = font
    # A is a base glyph with an opaque red A and translucent blue B layer.
    colr = [0, 1, 14, 20, 2].pack("n2N2n") + [36, 0, 2, 36, 0, 37, 1].pack("n7")
    cpal = [0, 2, 1, 2, 14, 0].pack("n4Nn") + [0, 0, 255, 255, 255, 0, 0, 128].pack("C8")
    Alhena::Font.new(sfnt_with(base, "COLR" => colr, "CPAL" => cpal))
  end

  def test_colr_layer_order_palette_and_alpha
    face = colr_font
    assert_equal [[36, 0], [37, 1]], face.color_layers(36)
    assert_equal [[255, 0, 0, 255], [0, 0, 255, 128]], face.palettes.first
    assert_nil face.color_layers(38)
    result = face.color_bitmap(36, size: 48)
    assert_operator result.rgba.bytes.each_slice(4).count { |r, _, b, a| r > 0 && b > 0 && a > 0 }, :>, 0
    assert_raises(ArgumentError) { face.color_bitmap(36, size: 48, palette: 2) }
    assert_raises(ArgumentError) { face.color_bitmap(36, size: 48, foreground: [-1, 0, 0, 255]) }
  end

  def test_png_filters_and_checksum_validation
    # Two RGB scanlines: filter None, then Sub.
    raw = "\x00\xff\x00\x00\x00\xff\x00\x01\x00\x00\xff\xff\x00\x01".b
    header = [2, 2, 8, 2, 0, 0, 0].pack("N2C5")
    chunk = ->(type, bytes) { [bytes.bytesize].pack("N") + type + bytes + [Zlib.crc32(type + bytes)].pack("N") }
    png = Alhena::PNG::SIGNATURE + chunk.call("IHDR", header) + chunk.call("IDAT", Zlib.deflate(raw)) + chunk.call("IEND", "")
    width, height, rgba = Alhena::PNG.decode(png)
    assert_equal [2, 2], [width, height]
    assert_equal [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255], rgba.bytes
    corrupt = png.dup
    corrupt.setbyte(20, corrupt.getbyte(20) ^ 1)
    assert_raises(Alhena::InvalidFont) { Alhena::PNG.decode(corrupt) }
  end

  def test_resize_interpolates_premultiplied_colors
    bitmap = Alhena::ColorBitmap.new(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 0, 0, 0].pack("C*"))
    scaled = bitmap.resize(2)
    assert_equal 4, scaled.width
    assert_equal [255, 0, 0], scaled.rgba.byteslice(4, 3).bytes
    assert_operator scaled.rgba.getbyte(7), :<, 255
  end

  def test_cbdt_composite_and_cycle_rejection
    base = font
    # Two entries: glyph 0 is a 2x1 gray bitmap; glyph 1 references it.
    bitmap = [1, 2, 0, 1, 2, 255, 128].pack("C*")
    composite = [1, 2, 0, 1, 2, 0, 1, 0, 0, 0].pack("C6n2c2")
    cblc = [3, 0, 1].pack("n2N")
    cblc << [56, 48, 2, 0].pack("N4") << "\0" * 24 << [0, 1, 16, 16, 8, 1].pack("n2C4")
    cblc << [0, 0, 16, 1, 1, 32].pack("n2Nn2N")
    cblc << [1, 1, 4, 0, bitmap.bytesize].pack("n2N3")
    cblc << [1, 8, 4 + bitmap.bytesize, 0, composite.bytesize].pack("n2N3")
    cbdt = [3, 0].pack("n2") + bitmap + composite
    face = Alhena::Font.new(sfnt_with(base, "CBLC" => cblc, "CBDT" => cbdt))
    assert_equal face.color_bitmap(0, size: 16).rgba, face.color_bitmap(1, size: 16).rgba
    cbdt[-4, 2] = [1].pack("n")
    cyclic = Alhena::Font.new(sfnt_with(base, "CBLC" => cblc, "CBDT" => cbdt))
    assert_raises(Alhena::InvalidFont) { cyclic.color_bitmap(1, size: 16) }
  end
end
