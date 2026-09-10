# frozen_string_literal: true

module Alhena
  # Straight (not premultiplied) sRGB RGBA8 pixels.
  class ColorBitmap
    attr_reader :width, :height, :left, :top, :rgba

    def initialize(width:, height:, rgba:, left: 0, top: 0)
      unless [width, height].all? { |n| n.is_a?(Integer) && n >= 0 && n <= Rasterizer::MAX_PIXELS } && width * height <= Rasterizer::MAX_PIXELS && rgba.bytesize == width * height * 4
        raise ArgumentError, "invalid color bitmap dimensions"
      end
      @width, @height, @left, @top, @rgba = width, height, left, top, rgba.b.freeze
      freeze
    end

    def to_bitmap
      alpha = String.new(capacity: width * height, encoding: Encoding::BINARY)
      (width * height).times { |i| alpha << rgba.getbyte(i * 4 + 3) }
      Bitmap.new(width: width, height: height, left: left, top: top, coverage: alpha)
    end

    # Bilinear resampling in premultiplied-alpha space prevents dark fringes.
    def resize(factor)
      return self if factor == 1
      raise ArgumentError, "scale must be positive and finite" unless factor.is_a?(Numeric) && factor.finite? && factor > 0
      target_width, target_height = (width * factor).round, (height * factor).round
      raise ArgumentError, "color bitmap exceeds size limit" if target_width * target_height > Rasterizer::MAX_PIXELS
      pixels = +"".b
      target_height.times do |y|
        sy = [[(y + 0.5) / factor - 0.5, 0].max, height - 1].min
        y0, y1, fy = sy.floor, [sy.floor + 1, height - 1].min, sy % 1
        target_width.times do |x|
          sx = [[(x + 0.5) / factor - 0.5, 0].max, width - 1].min
          x0, x1, fx = sx.floor, [sx.floor + 1, width - 1].min, sx % 1
          values = [0.0, 0.0, 0.0, 0.0]
          [[x0, y0, (1 - fx) * (1 - fy)], [x1, y0, fx * (1 - fy)], [x0, y1, (1 - fx) * fy], [x1, y1, fx * fy]].each do |px, py, weight|
            index = (py * width + px) * 4
            alpha = rgba.getbyte(index + 3)
            values[3] += alpha * weight
            3.times { |c| values[c] += rgba.getbyte(index + c) * alpha * weight }
          end
          3.times { |c| pixels << (values[3].zero? ? 0 : values[c] / values[3]).round.clamp(0, 255) }
          pixels << values[3].round.clamp(0, 255)
        end
      end
      self.class.new(width: target_width, height: target_height, left: (left * factor).round, top: (top * factor).round, rgba: pixels)
    end
  end

  EmbeddedBitmap = Data.define(:format, :data, :ppem, :left, :top, :width, :height)

  class Font
    alias rasterize_outline rasterize

    def rasterize(glyph, size:, **options)
      if @tables.key?("COLR") || @tables.key?("sbix") || @tables.key?("CBDT")
        bitmap = color_bitmap(glyph, size: size, subpixel_x: options.fetch(:subpixel_x, 0))
        return bitmap.to_bitmap if bitmap
      end
      rasterize_outline(glyph, size: size, **options)
    end

    # @param glyph [Integer] glyph ID, not a Unicode scalar
    # @param size [Numeric] requested pixels per em
    # @return [ColorBitmap, nil] straight RGBA8 or nil without color data
    def color_bitmap(glyph, size:, palette: 0, foreground: [0, 0, 0, 255], subpixel_x: 0)
      validate_glyph(glyph)
      scale_factor(size)
      raise ArgumentError, "palette must be a nonnegative integer" unless palette.is_a?(Integer) && palette >= 0
      raise ArgumentError, "foreground must be RGBA8" unless foreground.is_a?(Array) && foreground.length == 4 && foreground.all? { |n| n.is_a?(Integer) && (0..255).cover?(n) }
      if (layers = color_layers(glyph))
        colors = palettes.fetch(palette) { raise ArgumentError, "palette index out of range" }
        rendered = layers.map do |layer, color|
          rgba = color == 0xffff ? foreground : colors.fetch(color) { raise InvalidFont, "COLR palette index out of range" }
          [rasterize_outline(layer, size: size, subpixel_x: subpixel_x), rgba]
        end
        return compose_layers(rendered)
      end
      embedded = embedded_bitmap(glyph, size: size)
      return nil unless embedded
      render_embedded_bitmap(embedded, size)
    end

    def palettes
      return [] unless @tables.key?("CPAL")
      @palettes ||= begin
        data = table("CPAL")
        raise UnsupportedFont, "unsupported CPAL version" unless [0, 1].include?(data.u16(0))
        entries, count, records, offset = data.u16(2), data.u16(4), data.u16(6), data.u32(8)
        data.validate_bounds(12, count * 2)
        data.validate_bounds(offset, records * 4)
        count.times.map do |i|
          first = data.u16(12 + i * 2)
          raise InvalidFont, "palette exceeds color records" if first + entries > records
          entries.times.map do |j|
            blue, green, red, alpha = data.bytes(offset + (first + j) * 4, 4).bytes
            [red, green, blue, alpha].freeze
          end.freeze
        end.freeze
      end
    end

    def color_layers(glyph)
      validate_glyph(glyph)
      return nil unless @tables.key?("COLR")
      data = table("COLR")
      version = data.u16(0)
      raise UnsupportedFont, "unsupported COLR version" unless [0, 1].include?(version)
      count, base, layers, total = data.u16(2), data.u32(4), data.u32(8), data.u16(12)
      data.validate_bounds(base, count * 6)
      data.validate_bounds(layers, total * 4)
      lo, hi = 0, count
      while lo < hi
        mid = (lo + hi) / 2
        data.u16(base + mid * 6) < glyph ? lo = mid + 1 : hi = mid
      end
      return nil if lo == count || data.u16(base + lo * 6) != glyph
      first, length = data.u16(base + lo * 6 + 2), data.u16(base + lo * 6 + 4)
      raise InvalidFont, "COLR layer range exceeds table" if first + length > total
      length.times.map { |i| [data.u16(layers + (first + i) * 4), data.u16(layers + (first + i) * 4 + 2)] }
    end

    def embedded_bitmap(glyph, size:)
      validate_glyph(glyph)
      scale_factor(size)
      return sbix_bitmap(glyph, size) if @tables.key?("sbix")
      return cbdt_bitmap(glyph, size) if @tables.key?("CBDT") && @tables.key?("CBLC")
      nil
    end

    private

    def render_embedded_bitmap(embedded, size)
      raise UnsupportedFont, "embedded #{embedded.format.inspect} requires an image decoder; use embedded_bitmap to obtain the original bytes" unless embedded.format == :png || embedded.format == :rgba
      width, height, pixels = embedded.format == :png ? PNG.decode(embedded.data) : [embedded.width, embedded.height, embedded.data]
      if embedded.width && (embedded.width != width || embedded.height != height)
        raise InvalidFont, "embedded PNG and glyph metrics dimensions differ"
      end
      top = embedded.top || height
      bitmap = ColorBitmap.new(width: width, height: height, left: embedded.left, top: top, rgba: pixels)
      bitmap.resize(size.to_f / embedded.ppem)
    end

    def compose_layers(layers)
      layers = layers.reject { |bitmap, _| bitmap.width.zero? || bitmap.height.zero? }
      return ColorBitmap.new(width: 0, height: 0, rgba: "") if layers.empty?
      left = layers.map { |bitmap, _| bitmap.left }.min
      top = layers.map { |bitmap, _| bitmap.top }.max
      width = layers.map { |bitmap, _| bitmap.left + bitmap.width }.max - left
      height = top - layers.map { |bitmap, _| bitmap.top - bitmap.height }.min
      raise InvalidFont, "color layers exceed bitmap limit" if width * height > Rasterizer::MAX_PIXELS
      pixels = "\0".b * (width * height * 4)
      layers.each do |bitmap, color|
        bitmap.coverage.each_byte.with_index do |coverage, i|
          next if coverage.zero? || color[3].zero?
          index = ((top - bitmap.top + i / bitmap.width) * width + bitmap.left - left + i % bitmap.width) * 4
          source_alpha = coverage * color[3] / (255.0 * 255)
          destination_alpha = pixels.getbyte(index + 3) / 255.0
          alpha = source_alpha + destination_alpha * (1 - source_alpha)
          3.times do |channel|
            value = (color[channel] * source_alpha + pixels.getbyte(index + channel) * destination_alpha * (1 - source_alpha)) / alpha
            pixels.setbyte(index + channel, value.round.clamp(0, 255))
          end
          pixels.setbyte(index + 3, (alpha * 255).round.clamp(0, 255))
        end
      end
      ColorBitmap.new(width: width, height: height, left: left, top: top, rgba: pixels)
    end

    def sbix_bitmap(glyph, size)
      data = table("sbix")
      raise InvalidFont, "invalid sbix version" unless data.u16(0) == 1
      count = data.u32(4)
      data.validate_bounds(8, count * 4)
      strikes = count.times.map { |i| at = data.u32(8 + i * 4); [data.u16(at), at] }
      strikes.sort_by! { |ppem, _| [ppem >= size ? 0 : 1, (ppem - size).abs] }
      strikes.each do |ppem, strike|
        raise InvalidFont, "invalid bitmap strike size" if ppem.zero?
        target, visited = glyph, []
        loop do
          raise InvalidFont, "cyclic sbix duplicate" if visited.include?(target)
          visited << target
          raise InvalidFont, "sbix duplicate glyph out of range" unless target >= 0 && target < glyph_count
          first, last = data.u32(strike + 4 + target * 4), data.u32(strike + 8 + target * 4)
          break if first == last
          entry = Binary.new(data.bytes(strike + first, last - first))
          left, bottom, format = entry.i16(0), entry.i16(2), entry.bytes(4, 4)
          if format == "dupe"
            target = entry.u16(8)
            next
          end
          payload = entry.bytes(8, entry.size - 8).freeze
          width = height = nil
          if format == "png "
            png = Binary.new(payload)
            raise InvalidFont, "invalid embedded PNG" unless png.bytes(0, 8) == PNG::SIGNATURE
            width, height = png.u32(16), png.u32(20)
          end
          # sbix origin is relative to glyf's lower-left box when contours exist.
          if @tables.key?("glyf")
            path = outline(glyph)
            unless path.empty?
              bounds = path.bounds
              left += (bounds[0] * ppem.to_f / units_per_em).round
              bottom += (bounds[1] * ppem.to_f / units_per_em).round
            end
          end
          return EmbeddedBitmap.new(format: format.strip.to_sym, data: payload, ppem: ppem, left: left, top: height && bottom + height, width: width, height: height)
        end
      end
      nil
    end

    def cbdt_bitmap(glyph, size, ancestors = [])
      raise InvalidFont, "cyclic or deeply nested CBDT composite" if ancestors.include?(glyph) || ancestors.length > 5
      locations, bitmaps = table("CBLC"), table("CBDT")
      count = locations.u32(4)
      locations.validate_bounds(8, count * 48)
      strikes = count.times.map { |i| at = 8 + i * 48; [locations.u8(at + 45), at] }
      strikes.sort_by! { |ppem, _| [ppem >= size ? 0 : 1, (ppem - size).abs] }
      strikes.each do |ppem, strike|
        raise InvalidFont, "invalid CBDT strike size" if ppem.zero?
        next unless glyph >= locations.u16(strike + 40) && glyph <= locations.u16(strike + 42)
        list, count = locations.u32(strike), locations.u32(strike + 8)
        locations.validate_bounds(list, count * 8)
        count.times do |i|
          record = list + i * 8
          first, last = locations.u16(record), locations.u16(record + 2)
          next unless glyph >= first && glyph <= last
          at = list + locations.u32(record + 4)
          index_format, image_format, image_base = locations.u16(at), locations.u16(at + 2), locations.u32(at + 4)
          offset, length, metrics = cbdt_bitmap_location(locations, at, index_format, glyph, first, last)
          next unless offset && length.positive?
          image = Binary.new(bitmaps.bytes(image_base + offset, length))
          if [1, 2, 8, 17].include?(image_format)
            metrics = image.bytes(0, 5)
            image.position = 5
          elsif [6, 7, 9, 18].include?(image_format)
            metrics = image.bytes(0, 8)
            image.position = 8
          end
          raise InvalidFont, "CBDT bitmap has no metrics" unless metrics
          height, width, left, top = metrics.unpack("CCcc")
          if [17, 18, 19].include?(image_format)
            length = image.u32
            payload = image.bytes(image.position, length).freeze
            format = :png
          elsif [1, 2, 5, 6, 7].include?(image_format)
            payload = unpack_cbdt_bitmap(image, width, height, locations.u8(strike + 46), [1, 6].include?(image_format)).freeze
            format = :rgba
          elsif [8, 9].include?(image_format)
            image.u8 if image_format == 8 # padding after small metrics
            payload = compose_cbdt_pixels(image, width: width, height: height, ppem: ppem, glyph: glyph, ancestors: ancestors)
            format = :rgba
          else
            raise UnsupportedFont, "unsupported CBDT image format #{image_format}"
          end
          return EmbeddedBitmap.new(format: format, data: payload, ppem: ppem, left: left, top: top, width: width, height: height)
        end
      end
      nil
    end

    def compose_cbdt_pixels(image, width:, height:, ppem:, glyph:, ancestors:)
      components = image.u16
      image.validate_bounds(image.position, components * 4)
      payload = "\0".b * (width * height * 4)
      components.times do
        component, dx, dy = image.u16, image.i8, image.i8
        raise InvalidFont, "CBDT composite glyph out of range" if component >= glyph_count
        child = cbdt_bitmap(component, ppem, ancestors + [glyph])
        raise InvalidFont, "missing CBDT component bitmap" unless child
        cw, ch, pixels = child.format == :png ? PNG.decode(child.data) : [child.width, child.height, child.data]
        ch.times do |row|
          next unless row + dy >= 0 && row + dy < height
          cw.times do |col|
            next unless col + dx >= 0 && col + dx < width
            source = (row * cw + col) * 4
            target = ((row + dy) * width + col + dx) * 4
            sa, da = pixels.getbyte(source + 3) / 255.0, payload.getbyte(target + 3) / 255.0
            alpha = sa + da * (1 - sa)
            next if alpha.zero?
            3.times { |channel| payload.setbyte(target + channel, ((pixels.getbyte(source + channel) * sa + payload.getbyte(target + channel) * da * (1 - sa)) / alpha).round.clamp(0, 255)) }
            payload.setbyte(target + 3, (alpha * 255).round.clamp(0, 255))
          end
        end
      end
      payload.freeze
    end

    def cbdt_bitmap_location(data, at, format, glyph, first, last)
      metrics = nil
      case format
      when 1, 3
        width = format == 1 ? 4 : 2
        data.validate_bounds(at + 8, (last - first + 2) * width)
        offset = at + 8 + (glyph - first) * width
        a, b = format == 1 ? [data.u32(offset), data.u32(offset + 4)] : [data.u16(offset), data.u16(offset + 2)]
      when 2, 5
        size = data.u32(at + 8)
        metrics = data.bytes(at + 12, 8)
        index = glyph - first
        if format == 5
          count = data.u32(at + 20)
          data.validate_bounds(at + 24, count * 2)
          index = count.times.find { |i| data.u16(at + 24 + i * 2) == glyph }
          return [nil, nil, nil] unless index
        end
        a, b = index * size, (index + 1) * size
      when 4
        count = data.u32(at + 8)
        data.validate_bounds(at + 12, (count + 1) * 4)
        index = count.times.find { |i| data.u16(at + 12 + i * 4) == glyph }
        return [nil, nil, nil] unless index
        a, b = data.u16(at + 14 + index * 4), data.u16(at + 18 + index * 4)
      else
        raise UnsupportedFont, "unsupported CBLC index format #{format}"
      end
      raise InvalidFont, "unordered CBDT offsets" if b < a
      [a, b - a, metrics]
    end

    def unpack_cbdt_bitmap(data, width, height, depth, row_aligned)
      raise UnsupportedFont, "unsupported CBDT bit depth" unless [1, 2, 4, 8, 32].include?(depth)
      stride = row_aligned ? ((width * depth + 7) / 8) * 8 : width * depth
      bytes = data.bytes(data.position, (stride * height + 7) / 8)
      output = +"".b
      (width * height).times do |i|
        bit = (i / width) * stride + (i % width) * depth
        if depth == 32
          blue, green, red, alpha = bytes.byteslice(bit / 8, 4).bytes
          [red, green, blue].each { |c| output << (alpha.zero? ? 0 : (c * 255.0 / alpha).round.clamp(0, 255)) }
          output << alpha
        else
          value = (bytes.getbyte(bit / 8) >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
          output << 0 << 0 << 0 << (value * 255.0 / ((1 << depth) - 1)).round
        end
      end
      output
    end
  end
end
