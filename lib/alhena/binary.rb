# frozen_string_literal: true

module Alhena
  # Bounded big-endian reads shared by sfnt, glyf and CFF.
  class Binary
    attr_reader :data
    attr_accessor :position

    def initialize(data)
      @data, @position = data, 0
    end

    def size = @data.bytesize

    def bytes(offset, length)
      validate_bounds(offset, length)
      @data.byteslice(offset, length)
    end

    def validate_bounds(offset, length)
      raise InvalidFont, "font data out of bounds at #{offset} (#{length} bytes)" unless offset.is_a?(Integer) && length.is_a?(Integer) && offset >= 0 && length >= 0 && offset <= size - length
    end
    alias check validate_bounds

    def u8(offset = nil) = number(offset, 1, "C")
    def i8(offset = nil) = number(offset, 1, "c")
    def u16(offset = nil) = number(offset, 2, "n")
    def i16(offset = nil) = number(offset, 2, "s>")
    def u32(offset = nil) = number(offset, 4, "N")
    def i32(offset = nil) = number(offset, 4, "l>")
    def fixed(offset = nil) = i32(offset) / 65_536.0

    def u24(offset = nil)
      offset ||= @position
      validate_bounds(offset, 3)
      @position = offset + 3
      (@data.getbyte(offset) << 16) | (@data.getbyte(offset + 1) << 8) | @data.getbyte(offset + 2)
    end

    private

    def number(offset, length, format)
      offset ||= @position
      validate_bounds(offset, length)
      @position = offset + length
      @data.unpack1(format, offset: offset)
    end
  end
end
