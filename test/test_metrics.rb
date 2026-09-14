# frozen_string_literal: true

require_relative "test_helper"

class MetricsTest < Minitest::Test
  def test_advance_width_and_measure_use_font_metrics_without_rasterizing
    face = font("NotoSans-Regular.ttf")
    text = "Hello"
    expected = text.each_char.sum { |character| face.advance(face.glyph_id(character), size: 18) }

    assert_in_delta expected, face.advance_width(text.codepoints, size: 18)
    assert_in_delta face.advance_width(["A".ord], size: 18), face.measure("A\ufe0f", size: 18).width
    metrics = face.measure(text, size: 18)
    assert_in_delta expected, metrics.width
    assert_equal 0.0, face.measure("", size: 18).width
    assert_in_delta face.ascent * 18.0 / face.units_per_em, metrics.ascent
    assert_in_delta face.descent * 18.0 / face.units_per_em, metrics.descent
    assert_in_delta face.line_gap * 18.0 / face.units_per_em, metrics.line_gap
    assert_operator metrics.descent, :<, 0
    assert metrics.frozen?
  end

  def test_metrics_validate_input_and_report_unsupported_layout_features
    face = font

    assert_raises(ArgumentError) { face.advance_width("A", size: 12) }
    assert_raises(ArgumentError) { face.advance_width([-1], size: 12) }
    assert_raises(ArgumentError) { face.advance_width([], size: 0) }
    assert_raises(ArgumentError) { face.advance_width([], size: Complex(1, 1)) }
    assert_raises(ArgumentError) { face.measure("\xff".b, size: 12) }
    assert_raises(ArgumentError) { face.measure("A", size: 0) }
    assert_raises(Alhena::UnsupportedFont) { face.measure("A", size: 12, features: [:kern]) }
  end

  def test_downsampled_fill_combines_outlines_at_the_requested_scale
    outlines = [rectangle(0, 0, 4, 4), rectangle(6, 0, 2, 4)]
    snapshots = outlines.map { |outline| [outline.commands.dup, outline.coordinates.dup] }
    bitmap = Alhena::Rasterizer.new(width: 1, height: 1).fill_downsampled(
      outlines, scale: 0.5, width: 5, height: 2
    )

    assert_equal "@@ @ \n@@ @ ", bitmap.to_ascii
    assert_equal [5, 2, 1], [bitmap.width, bitmap.height, bitmap.channels]
    assert_equal snapshots, outlines.map { |outline| [outline.commands, outline.coordinates] }
    assert_equal "\0" * 4, Alhena::Rasterizer.new(width: 1, height: 1)
      .fill_downsampled([], scale: 1, width: 2, height: 2).coverage
    assert_raises(ArgumentError) do
      Alhena::Rasterizer.new(width: 1, height: 1).fill_downsampled([Object.new], scale: 1, width: 1, height: 1)
    end
    assert_raises(ArgumentError) do
      Alhena::Rasterizer.new(width: 1, height: 1).fill_downsampled(outlines, scale: 0, width: 1, height: 1)
    end
    assert_raises(ArgumentError) do
      Alhena::Rasterizer.new(width: 1, height: 1).fill_downsampled(
        outlines, scale: Complex(1, 1), width: 1, height: 1
      )
    end
    assert_raises(ArgumentError) do
      Alhena::Rasterizer.new(width: 1, height: 1).fill_downsampled(outlines, scale: 1, width: -1, height: 1)
    end
  end

  private

  def rectangle(x, y, width, height)
    Alhena::Outline.new.move_to(x, y).line_to(x + width, y).line_to(x + width, y + height)
      .line_to(x, y + height).close
  end
end
