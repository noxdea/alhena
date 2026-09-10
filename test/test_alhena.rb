# frozen_string_literal: true

require_relative "test_helper"

class AlhenaTest < Minitest::Test
  def test_font_metadata_and_glyphs
    face = font
    assert_equal "Abel", face.family
    assert_equal 2048, face.units_per_em
    assert_equal 36, face.glyph_id("A")
    assert_equal 0, face.glyph_id(0x10ffff)
    assert_in_delta 11.1328125, face.advance(36, size: 24)
    assert_equal 400, face.os2[:weight]
    refute face.post[:fixed_pitch]
    refute face.outline(36).empty?
    assert face.rasterize(face.glyph_id(" "), size: 24).coverage.empty?
    assert_raises(ArgumentError) { face.glyph_id(-1) }
    assert_raises(ArgumentError) { face.outline(face.glyph_count) }
    assert_raises(ArgumentError) { face.rasterize(36, size: 0) }
    assert_raises(ArgumentError) { face.rasterize(36, size: Float::INFINITY) }
  end

  def test_composite_and_cff_outlines
    face = font("NotoSans-Regular.ttf")
    glyph = face.glyph_id("é")
    path = face.outline(glyph)
    assert_operator path.commands.count(:move_to), :>=, 3
    face = font("SourceSans3-Regular.otf")
    face.glyph_count.times { |id| assert_kind_of Alhena::Outline, face.outline(id) }
    assert_includes face.outline(face.glyph_id("S")).commands, :cubic_to
    cid = font("SourceHanSansJP-Regular.otf")
    "日本語あいう漢字龍鬱".each_char do |character|
      refute_equal 0, cid.glyph_id(character)
      assert_operator cid.rasterize(cid.glyph_id(character), size: 48).coverage.bytes.sum, :>, 0
    end
    assert_in_delta 48, cid.advance(cid.glyph_id("日"), size: 48, vertical: true)
  end

  def rectangle(x, y, width, height)
    Alhena::Outline.new.move_to(x, y).line_to(x + width, y).line_to(x + width, y + height).line_to(x, y + height).close
  end

  def test_analytic_area_clipping_and_holes
    raster = Alhena::Rasterizer.new(width: 20, height: 20)
    random = Random.new(42)
    200.times do
      x, y = random.rand * 10 - 5, random.rand * 10 - 5
      width, height = 5 + random.rand * 20, 5 + random.rand * 20
      bmp = raster.fill(rectangle(x, y, width, height))
      area = ([x + width, 20].min - [x, 0].max) * ([y + height, 20].min - [y, 0].max)
      assert_in_delta area, bmp.coverage.bytes.sum / 255.0, area * 0.01
    end
    path = rectangle(-20, -20, 60, 60)
    path.move_to(5, 5).line_to(5, 15).line_to(15, 15).line_to(15, 5).close
    bitmap = raster.fill(path)
    assert_equal 300 * 255, bitmap.coverage.bytes.sum
    assert_equal 0, bitmap.coverage.getbyte(10 * 20 + 10)
    triangle = Alhena::Outline.new.move_to(-10, 0).line_to(30, 0).line_to(10, 20).close
    assert_in_delta 300, raster.fill(triangle).coverage.bytes.sum / 255.0, 0.1
    200.times do
      count = random.rand(3..12)
      points = count.times.map do |i|
        angle, radius = i * 2 * Math::PI / count, random.rand(2.0..8.0)
        [10 + radius * Math.cos(angle), 10 + radius * Math.sin(angle)]
      end
      polygon = Alhena::Outline.new.move_to(*points.first)
      points.drop(1).each { |point| polygon.line_to(*point) }
      polygon.close
      area = points.each_with_index.sum { |(x, y), i| following = points[(i + 1) % count]; x * following[1] - y * following[0] }.abs / 2.0
      assert_in_delta area, raster.fill(polygon).coverage.bytes.sum / 255.0, area * 0.01
    end
  end

  def test_curves_transform_and_implicit_closure
    quadratic = Alhena::Outline.new.move_to(0, 0).quad_to(10, 20, 20, 0).close
    cubic = Alhena::Outline.new.move_to(0, 0).cubic_to(20.0 / 3, 40.0 / 3, 40.0 / 3, 40.0 / 3, 20, 0).close
    raster = Alhena::Rasterizer.new(width: 20, height: 20, tolerance: 0.05)
    assert_in_delta 400.0 / 3, raster.fill(quadratic).coverage.bytes.sum / 255.0, 1
    assert_operator bitmap_error(raster.fill(quadratic), raster.fill(cubic)), :<, 0.1
    assert_equal quadratic.coordinates, cubic.to_quadratic.coordinates
    refute_includes cubic.to_quadratic.commands, :cubic_to
    open = Alhena::Outline.new.move_to(0, 0).line_to(10, 0).line_to(10, 10).line_to(0, 10)
    assert_equal 100 * 255, raster.fill(open).coverage.bytes.sum
    assert_equal [2.0, 3.0, 22.0, 23.0], open.transform([2, 0, 0, 2, 2, 3]).bounds
  end

  def test_lcd_gamma_and_darkening
    path = rectangle(0.5, 0, 3, 3)
    raster = Alhena::Rasterizer.new(width: 5, height: 3)
    plain = raster.fill(path)
    assert_operator raster.fill(path, gamma: 2).coverage.bytes.sum, :>, plain.coverage.bytes.sum
    assert_operator raster.fill(path, darkening: 0.2).coverage.bytes.sum, :>, plain.coverage.bytes.sum
    rgb, bgr = raster.fill(path, lcd: :rgb), raster.fill(path, lcd: :bgr)
    assert_equal 3, rgb.channels
    assert_equal 45, rgb.coverage.bytesize
    assert_equal rgb.coverage.bytes.each_slice(3).flat_map(&:reverse), bgr.coverage.bytes
    assert_raises(ArgumentError) { raster.fill(path, gamma: 0) }
    assert_raises(ArgumentError) { raster.fill(path, lcd: :invalid) }
    assert_raises(ArgumentError) { Alhena::Rasterizer.new(width: 10**9, height: 10**9) }
    assert_raises(ArgumentError) { Alhena::Rasterizer.new(width: 0, height: 10**12) }
    assert_empty Alhena::Rasterizer.new(width: 0, height: 2).fill(path).coverage
  end

  def test_cache_quantization_lru_and_memory_limits
    face, cache = font, Alhena::Cache.new(capacity: 2)
    first = cache.rasterize(face, 36, size: 24, subpixel_x: 0.23)
    assert_same first, cache.rasterize(face, 36, size: 24, subpixel_x: 0.25)
    cache.rasterize(face, 37, size: 24)
    cache.rasterize(face, 36, size: 24, subpixel_x: 0.25)
    cache.rasterize(face, 38, size: 24)
    assert_same first, cache.rasterize(face, 36, size: 24, subpixel_x: 0.25)
    cache.prewarm(face, "ABC", 24)
    assert_equal 2, cache.size
    assert_operator cache.bytesize, :>, 0
    cache.clear
    assert_equal 0, cache.bytesize
    cache = Alhena::Cache.new(max_bytes: 1)
    cache.rasterize(face, 36, size: 24)
    assert_equal 0, cache.size
  end

  def test_truncation_and_bounds
    bytes = File.binread(font_path)
    [0, 1, 4, 12, 256, bytes.size - 2].each do |length|
      assert_raises(Alhena::Error) { Alhena::Font.new(bytes.byteslice(0, length)).outline(36) }
    end
    corrupt = bytes.dup
    corrupt[20, 4] = [0xffffffff].pack("N")
    assert_raises(Alhena::InvalidFont) { Alhena::Font.new(corrupt) }
  end
end
