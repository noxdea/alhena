# frozen_string_literal: true

module Alhena
  # Immutable, tightly packed R8 or RGB8 coverage. Y increases downwards.
  class Bitmap
    attr_reader :width, :height, :left, :top, :coverage, :channels

    def initialize(width:, height:, coverage:, left: 0, top: 0, channels: 1)
      unless [width, height].all? { |n| n.is_a?(Integer) && n >= 0 } && [1, 3].include?(channels) && coverage.bytesize == width * height * channels
        raise ArgumentError, "invalid bitmap dimensions or coverage length"
      end
      @width, @height, @left, @top, @channels = width, height, left, top, channels
      @coverage = coverage.b.freeze
      freeze
    end

    def to_ascii(ramp: " .:-=+*#%@")
      raise ArgumentError, "ramp is empty" if ramp.empty?
      (0...height).map do |y|
        (0...width).map do |x|
          value = (0...channels).sum { |c| coverage.getbyte((y * width + x) * channels + c) } / channels
          ramp[(value * (ramp.length - 1) / 255.0).round]
        end.join
      end.join("\n")
    end
  end
end
