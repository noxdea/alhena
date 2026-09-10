# frozen_string_literal: true

require_relative "../test_helper"
begin
  require_relative "../support/freetype"
rescue LoadError
end

class VariationOracleTest < Minitest::Test
  def test_variable_truetype_and_cff2_match_freetype
    skip "FreeType is not installed" unless defined?(FreeTypeOracle::Face)
    {"Roboto[wdth,wght].ttf" => [{wght: 100}, {wght: 900}, {wght: 650, wdth: 80}],
     "SourceSerif4Variable-Roman.otf" => [{wght: 200}, {wght: 900}, {wght: 650, opsz: 48}]}.each do |name, settings|
      base = font(name)
      FreeTypeOracle.with_face(font_path(name)) do |reference|
        settings.each do |axes|
          instance = base.variation(axes)
          values = base.axes.map { |tag, axis| axes.fetch(tag.to_sym, axis[:default]) }
          FreeTypeOracle.set_axes(reference, values)
          "ABCSéÅœg0123".each_char do |character|
            glyph = instance.glyph_id(character)
            [14, 24, 48].each do |size|
              expected = FreeTypeOracle.rasterize(reference, glyph, size: size)
              actual = instance.rasterize(glyph, size: size)
              error = bitmap_error(expected, actual)
              assert_operator error, :<=, 2, "#{name} #{axes} #{character} #{size}px: MAE #{error}"
            end
            FreeTypeOracle.raise_on_error FreeTypeOracle.FT_Load_Glyph(reference, glyph, 1 | 2 | 8)
            expected_advance = FreeTypeOracle::Slot.new(reference.glyph).metrics[4]
            assert_in_delta expected_advance, instance.advance(glyph), 1.0
          end
        end
      end
    end
  end
end
