# frozen_string_literal: true

require_relative "test_helper"

class InteroperabilityTest < Minitest::Test
  def test_original_data_and_variation_coordinates_are_immutable
    path = File.expand_path("fonts/Abel-Regular.ttf", __dir__)
    font = Alhena::Font.open(path)
    assert_equal File.binread(path), font.data
    assert font.data.frozen?
    assert font.axis_values.frozen?
    assert_equal font.glyph_id("A"), Alhena::Font.new(font.data, index: font.index, axes: font.axis_values).glyph_id("A")
  end
end
