# frozen_string_literal: true

module Alhena
  # Per-instance LRU, bounded by entry count and optionally coverage bytes.
  class Cache
    attr_reader :capacity, :bytesize

    def initialize(capacity: 4096, max_bytes: nil)
      raise ArgumentError, "capacity must be positive" unless capacity.is_a?(Integer) && capacity > 0
      raise ArgumentError, "max_bytes must be positive" if max_bytes && !(max_bytes.is_a?(Integer) && max_bytes > 0)
      @capacity, @max_bytes, @bytesize, @entries = capacity, max_bytes, 0, {}
    end

    def size = @entries.size

    # @return [Bitmap] immutable coverage, reused on an LRU cache hit
    def rasterize(font, glyph, size:, subpixel_x: 0, **options)
      raise ArgumentError, "invalid subpixel position" unless subpixel_x.is_a?(Numeric) && subpixel_x.finite?
      bucket = (subpixel_x * 4).round
      key = [font, glyph, size, bucket, options]
      if (hit = @entries.delete(key))
        return @entries[key] = hit
      end
      bitmap = font.rasterize(glyph, size: size, subpixel_x: bucket / 4.0, **options)
      return bitmap if @max_bytes && bitmap.coverage.bytesize > @max_bytes
      @entries[key] = bitmap
      @bytesize += bitmap.coverage.bytesize
      while @entries.size > @capacity || (@max_bytes && @bytesize > @max_bytes)
        @bytesize -= @entries.shift.last.coverage.bytesize
      end
      bitmap
    end

    def prewarm(font, text, size = nil, **options)
      size ||= options.delete(:size)
      text.each_codepoint { |code| rasterize(font, font.glyph_id(code), size: size, **options) }
      self
    end

    def clear
      @entries.clear
      @bytesize = 0
      self
    end
  end
end
