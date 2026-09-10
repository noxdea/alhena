# frozen_string_literal: true

require "zlib"

module Alhena
  # PNG decoder for embedded bitmap glyphs; Ruby stdlib only, bounded inflate.
  module PNG
    SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
    PASSES = [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]].freeze

    class << self
      def decode(bytes)
        header, compressed, palette, transparency = read_chunks(Binary.new(bytes))
        width, height, _depth, _color, _compression, _filter, interlace = header
        channels = validate_header(header)
        passes = interlace.zero? ? [[0, 0, 1, 1]] : PASSES
        expected = inflated_size(header, channels, passes)
        raw = inflate(compressed, expected)
        pixels = decode_pixels(raw, header: header, channels: channels, passes: passes, palette: palette, transparency: transparency)
        [width, height, pixels]
      rescue Zlib::Error => error
        raise InvalidFont, "invalid PNG compression: #{error.message}"
      end

      private

      def read_chunks(source)
        raise InvalidFont, "invalid PNG signature" unless source.bytes(0, 8) == SIGNATURE
        offset = 8
        compressed = +"".b
        palette = transparency = header = nil
        ended = false
        while offset < source.size
          length = source.u32(offset)
          type = source.bytes(offset + 4, 4)
          payload = source.bytes(offset + 8, length)
          crc = source.u32(offset + 8 + length)
          raise InvalidFont, "PNG checksum mismatch" unless Zlib.crc32(type + payload) == crc
          case type
          when "IHDR"
            raise InvalidFont, "invalid PNG header" unless length == 13 && offset == 8
            header = payload.unpack("N2C5")
          when "PLTE" then palette = payload.bytes.each_slice(3).to_a
          when "tRNS" then transparency = payload
          when "IDAT" then compressed << payload
          when "IEND"
            ended = true
            break
          else
            raise UnsupportedFont, "unsupported critical PNG chunk #{type}" if type.getbyte(0) & 32 == 0
          end
          offset += length + 12
        end
        raise InvalidFont, "incomplete PNG" unless header && ended
        [header, compressed, palette, transparency]
      end

      def validate_header(header)
        width, height, depth, color, compression, filter, interlace = header
        raise InvalidFont, "PNG dimensions exceed limit" unless width > 0 && height > 0 && width * height <= Rasterizer::MAX_PIXELS
        channels = {0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[color]
        valid_depths = {0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16]}
        raise UnsupportedFont, "unsupported PNG format" unless channels && valid_depths[color].include?(depth) && compression.zero? && filter.zero? && [0, 1].include?(interlace)
        channels
      end

      def inflated_size(header, channels, passes)
        width, height, depth = header
        passes.sum do |x, y, dx, dy|
          w, h = pass_dimensions(width, height, x, y, dx, dy)
          w.zero? || h.zero? ? 0 : ((w * channels * depth + 7) / 8 + 1) * h
        end
      end

      def pass_dimensions(width, height, x, y, dx, dy)
        [[0, (width - x + dx - 1) / dx].max, [0, (height - y + dy - 1) / dy].max]
      end

      def inflate(compressed, expected)
        raw = +"".b
        inflater = Zlib::Inflate.new
        begin
          inflater.inflate(compressed) do |chunk|
            raise InvalidFont, "PNG decompression exceeds image size" if raw.bytesize + chunk.bytesize > expected
            raw << chunk
          end
          raise InvalidFont, "incomplete PNG compression stream" unless inflater.finished?
        ensure
          inflater.close
        end
        raise InvalidFont, "PNG scanline length mismatch" unless raw.bytesize == expected
        raw
      end

      def decode_pixels(raw, header:, channels:, passes:, palette:, transparency:)
        width, height, depth, color = header
        output, at = "\0".b * (width * height * 4), 0
        passes.each do |x0, y0, dx, dy|
          w, h = pass_dimensions(width, height, x0, y0, dx, dy)
          next if w.zero? || h.zero?
          stride = (w * channels * depth + 7) / 8
          pixel_bytes = [(channels * depth + 7) / 8, 1].max
          previous = Array.new(stride, 0)
          h.times do |row|
            current = raw.byteslice(at + 1, stride).bytes
            unfilter(current, previous, raw.getbyte(at), pixel_bytes)
            at += stride + 1
            w.times do |col|
              rgba = rgba_for(pixel_samples(current, col, channels, depth), color, depth, palette, transparency)
              target = ((y0 + row * dy) * width + x0 + col * dx) * 4
              rgba.each_with_index { |value, channel| output.setbyte(target + channel, value) }
            end
            previous = current
          end
        end
        output
      end

      def unfilter(current, previous, mode, pixel_bytes)
        raise InvalidFont, "invalid PNG filter" unless (0..4).cover?(mode)
        current.each_index do |i|
          a, b, c = i >= pixel_bytes ? current[i - pixel_bytes] : 0, previous[i], i >= pixel_bytes ? previous[i - pixel_bytes] : 0
          predictor = case mode
          when 0 then 0
          when 1 then a
          when 2 then b
          when 3 then (a + b) / 2
          when 4
            p = a + b - c
            pa, pb, pc = (p - a).abs, (p - b).abs, (p - c).abs
            pa <= pb && pa <= pc ? a : pb <= pc ? b : c
          end
          current[i] = (current[i] + predictor) & 255
        end
      end

      def pixel_samples(bytes, column, channels, depth)
        channels.times.map do |channel|
          index = column * channels + channel
          if depth == 16
            (bytes[index * 2] << 8) | bytes[index * 2 + 1]
          elsif depth == 8
            bytes[index]
          else
            (bytes[index * depth / 8] >> (8 - depth - index * depth % 8)) & ((1 << depth) - 1)
          end
        end
      end

      def rgba_for(samples, color, depth, palette, transparency)
        case color
        when 0
          value = (samples[0] * 255.0 / ((1 << depth) - 1)).round
          alpha = transparency && samples[0] == transparency.unpack1("n") ? 0 : 255
          [value, value, value, alpha]
        when 2
          alpha = transparency && samples == transparency.unpack("n3") ? 0 : 255
          samples.map { |value| depth == 16 ? value >> 8 : value } + [alpha]
        when 3
          rgb = palette && palette[samples[0]]
          raise InvalidFont, "PNG palette index out of range" unless rgb && rgb.length == 3
          rgb + [transparency&.getbyte(samples[0]) || 255]
        when 4
          gray, alpha = samples.map { |value| depth == 16 ? value >> 8 : value }
          [gray, gray, gray, alpha]
        when 6 then samples.map { |value| depth == 16 ? value >> 8 : value }
        end
      end
    end
  end
end
