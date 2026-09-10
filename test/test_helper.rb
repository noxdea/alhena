# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "alhena"
require "minitest/autorun"

module FontFixtures
  FONTS = File.expand_path("fonts", __dir__)

  def font_path(name = "Abel-Regular.ttf") = File.join(FONTS, name)
  def font(name = "Abel-Regular.ttf") = Alhena::Font.open(font_path(name))

  def bitmap_error(a, b)
    left, top = [a.left, b.left].min, [a.top, b.top].max
    right, bottom = [a.left + a.width, b.left + b.width].max, [a.top - a.height, b.top - b.height].min
    return 0.0 if right == left || bottom == top
    total = 0
    bottom.upto(top - 1) do |y|
      left.upto(right - 1) do |x|
        values = [a, b].map do |bmp|
          col, row = x - bmp.left, bmp.top - 1 - y
          col >= 0 && col < bmp.width && row >= 0 && row < bmp.height ? bmp.coverage.getbyte(row * bmp.width + col) : 0
        end
        total += (values[0] - values[1]).abs
      end
    end
    total.to_f / ((right - left) * (top - bottom))
  end
end

class Minitest::Test
  include FontFixtures
end
