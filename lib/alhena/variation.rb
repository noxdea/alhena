# frozen_string_literal: true

module Alhena
  # Shared ItemVariationStore interpolation used by CFF2, HVAR and VVAR.
  class VariationStore
    def initialize(data, offset, coordinates)
      @data, @offset, @coordinates = data, offset, coordinates
      raise InvalidFont, "invalid item variation store" unless data.u16(offset) == 1
      region_offset = offset + data.u32(offset + 2)
      count = data.u16(offset + 6)
      data.validate_bounds(offset + 8, count * 4)
      @items = count.times.map { |i| offset + data.u32(offset + 8 + i * 4) }
      axes, regions = data.u16(region_offset), data.u16(region_offset + 2)
      raise InvalidFont, "variation axis count mismatch" unless axes == coordinates.length
      data.validate_bounds(region_offset + 4, axes * regions * 6)
      @scalars = regions.times.map do |region|
        scalar = 1.0
        axes.times do |axis|
          at = region_offset + 4 + (region * axes + axis) * 6
          start, peak, finish = 3.times.map { |i| data.i16(at + i * 2) / 16_384.0 }
          next if peak.zero? || start > peak || peak > finish || (start < 0 && finish > 0)
          coordinate = coordinates[axis]
          scalar *= if coordinate == peak
            1.0
          elsif coordinate <= start || coordinate >= finish
            0.0
          elsif coordinate < peak
            (coordinate - start) / (peak - start)
          else
            (finish - coordinate) / (finish - peak)
          end
        end
        scalar
      end
    end

    def region_scalars(index)
      at = @items.fetch(index) { raise InvalidFont, "variation outer index out of range" }
      count = @data.u16(at + 4)
      @data.validate_bounds(at + 6, count * 2)
      count.times.map { |i| @scalars.fetch(@data.u16(at + 6 + i * 2)) { raise InvalidFont, "variation region out of range" } }
    end

    def delta(outer, inner)
      return 0.0 if outer == 0xffff && inner == 0xffff
      at = @items.fetch(outer) { raise InvalidFont, "variation outer index out of range" }
      items, words, count = @data.u16(at), @data.u16(at + 2), @data.u16(at + 4)
      raise InvalidFont, "variation inner index out of range" unless inner >= 0 && inner < items
      long = words & 0x8000 != 0
      words &= 0x7fff
      raise InvalidFont, "invalid variation word count" if words > count
      stride = long ? words * 4 + (count - words) * 2 : words * 2 + count - words
      position = at + 6 + count * 2 + inner * stride
      scalars = region_scalars(outer)
      @data.validate_bounds(position, stride)
      @data.position = position
      scalars.each_with_index.sum do |scalar, i|
        value = long ? (i < words ? @data.i32 : @data.i16) : (i < words ? @data.i16 : @data.i8)
        value * scalar
      end
    end

    def self.index(data, at, glyph)
      return [0, glyph] if at.zero?
      format, entry_format = data.u8(at), data.u8(at + 1)
      raise InvalidFont, "invalid variation index map" unless [0, 1].include?(format)
      count = format.zero? ? data.u16(at + 2) : data.u32(at + 2)
      return [0xffff, 0xffff] if count.zero?
      width = ((entry_format >> 4) & 3) + 1
      bits = (entry_format & 15) + 1
      start = at + (format.zero? ? 4 : 6) + [glyph, count - 1].min * width
      value = 0
      width.times { |i| value = (value << 8) | data.u8(start + i) }
      [value >> bits, value & ((1 << bits) - 1)]
    end
  end

  class Font
    # Axis descriptors are in fvar order; coordinates use user-space values.
    def axes
      @axes ||= begin
        if @tables.key?("fvar")
          data = table("fvar")
          offset, count, stride = data.u16(4), data.u16(8), data.u16(10)
          raise InvalidFont, "invalid fvar axis record size" if stride < 20
          data.validate_bounds(offset, count * stride)
          count.times.to_h do |i|
            at = offset + i * stride
            tag = data.bytes(at, 4)
            minimum, default, maximum = data.fixed(at + 4), data.fixed(at + 8), data.fixed(at + 12)
            raise InvalidFont, "invalid fvar axis range" unless minimum <= default && default <= maximum
            [tag, {min: minimum, default: default, max: maximum, hidden: data.u16(at + 16) & 1 != 0, name: names[data.u16(at + 18)]}.freeze]
          end.freeze
        else
          {}.freeze
        end
      end
    end

    def variation(values)
      self.class.new(@binary.data, index: @index, axes: @axis_values.merge(values.transform_keys(&:to_s)))
    end

    def normalized_coordinates
      @normalized_coordinates ||= begin
        unknown = @axis_values.keys - axes.keys
        raise ArgumentError, "unknown variation axes: #{unknown.join(', ')}" unless unknown.empty?
        values = axes.map do |tag, axis|
          value = @axis_values.fetch(tag, axis[:default])
          raise ArgumentError, "axis values must be finite" unless value.is_a?(Numeric) && value.finite?
          value = [[value, axis[:min]].max, axis[:max]].min
          value == axis[:default] ? 0.0 : (value - axis[:default]) / (value < axis[:default] ? axis[:default] - axis[:min] : axis[:max] - axis[:default])
        end
        if @tables.key?("avar")
          data = table("avar")
          raise UnsupportedFont, "avar version 2 is unsupported" unless data.u16(0) == 1
          raise InvalidFont, "avar axis count mismatch" unless data.u16(6) == values.length
          data.position = 8
          values.map! do |value|
            count = data.u16
            maps = count.times.map { [data.i16 / 16_384.0, data.i16 / 16_384.0] }
            raise InvalidFont, "invalid avar segment map" unless maps.length >= 3 && maps.each_cons(2).all? { |a, b| a[0] < b[0] }
            match = maps.find { |from, _| from == value }
            if match
              match[1]
            else
              pair = maps.each_cons(2).find { |a, b| value > a[0] && value < b[0] }
              raise InvalidFont, "avar map does not cover coordinate" unless pair
              a, b = pair
              a[1] + (b[1] - a[1]) * (value - a[0]) / (b[0] - a[0])
            end
          end
        end
        values.freeze
      end
    end

    private

    def variable? = @tables.key?("fvar") && normalized_coordinates.any? { |n| n != 0 }

    def metric(glyph, vertical: false)
      result = raw_metric(glyph, vertical: vertical)
      return result unless variable?
      tag = vertical ? "VVAR" : "HVAR"
      if @tables.key?(tag)
        data = table(tag)
        @metric_stores ||= {}
        store = @metric_stores[tag] ||= VariationStore.new(data, data.u32(4), normalized_coordinates)
        result[0] += store.delta(*VariationStore.index(data, data.u32(8), glyph))
        mapping = data.u32(12)
        result[1] += store.delta(*VariationStore.index(data, mapping, glyph)) unless mapping.zero?
      elsif @tables.key?("gvar")
        @metric_deltas ||= {}
        truetype_glyph(glyph, []) unless @metric_deltas.key?(glyph)
        deltas = @metric_deltas.fetch(glyph, [0, 0])
        result[0] += deltas[vertical ? 1 : 0]
      end
      result
    end

    def vary_points(glyph, points, ends, glyph_data)
      return points unless variable? && @tables.key?("gvar")
      # Phantom points let gvar supply advances when HVAR/VVAR are absent.
      advance, bearing = raw_metric(glyph)
      xmin = glyph_data.size >= 10 ? glyph_data.i16(2) : 0
      ymax = glyph_data.size >= 10 ? glyph_data.i16(8) : 0
      left = xmin - bearing
      vadvance, vbearing = @tables.key?("vmtx") ? raw_metric(glyph, vertical: true) : [ascent - descent, ascent - ymax]
      top = ymax + vbearing
      all = points + [[left, 0], [left + advance, 0], [0, top], [0, top - vadvance]]
      deltas = glyph_deltas(glyph, all, ends)
      @metric_deltas ||= {}
      @metric_deltas[glyph] = [deltas[-3][0] - deltas[-4][0], deltas[-2][1] - deltas[-1][1]]
      points.each_with_index.map { |(x, y), i| [x + deltas[i][0], y + deltas[i][1]] }
    end

    def glyph_deltas(glyph, points, ends)
      data = table("gvar")
      axis_count = data.u16(4)
      raise InvalidFont, "gvar axis count mismatch" unless axis_count == normalized_coordinates.length
      raise InvalidFont, "gvar glyph count mismatch" unless data.u16(12) == glyph_count
      long = data.u16(14) & 1 != 0
      base = data.u32(16)
      first = long ? data.u32(20 + glyph * 4) : data.u16(20 + glyph * 2) * 2
      last = long ? data.u32(24 + glyph * 4) : data.u16(22 + glyph * 2) * 2
      result = Array.new(points.length) { [0.0, 0.0] }
      return result if first == last
      record = Binary.new(data.bytes(base + first, last - first))
      flags, serialized = record.u16, record.u16
      headers = (flags & 0xfff).times.map do
        size, index = record.u16, record.u16
        peak = if index & 0x8000 != 0
          axis_count.times.map { record.i16 / 16_384.0 }
        else
          shared = index & 0xfff
          raise InvalidFont, "gvar shared tuple out of range" if shared >= data.u16(6)
          location = data.u32(8) + shared * axis_count * 2
          axis_count.times.map { |i| data.i16(location + i * 2) / 16_384.0 }
        end
        start, finish = if index & 0x4000 != 0
          [axis_count.times.map { record.i16 / 16_384.0 }, axis_count.times.map { record.i16 / 16_384.0 }]
        end
        [size, index, peak, start, finish]
      end
      raise InvalidFont, "gvar expansion exceeds work limit" if points.length * headers.length > 4_000_000
      raise InvalidFont, "overlapping gvar header and data" if record.position > serialized
      record.position = serialized
      shared_points = flags & 0x8000 != 0 ? packed_points(record, points.length) : nil
      headers.each do |size, index, peak, start, finish|
        tuple = Binary.new(record.bytes(record.position, size))
        record.position += size
        scalar = tuple_scalar(peak, start, finish)
        next if scalar.zero?
        selected = index & 0x2000 != 0 ? packed_points(tuple, points.length) : shared_points
        selected ||= (0...points.length).to_a
        dx, dy = packed_deltas(tuple, selected.length), packed_deltas(tuple, selected.length)
        offsets = Array.new(points.length)
        selected.each_with_index do |point, i|
          offsets[point] ||= [0.0, 0.0]
          offsets[point][0] += dx[i]
          offsets[point][1] += dy[i]
        end
        interpolate_untouched(points, offsets, ends)
        offsets.each_with_index do |delta, i|
          next unless delta
          result[i][0] += delta[0] * scalar
          result[i][1] += delta[1] * scalar
        end
      end
      result
    end

    def tuple_scalar(peak, start, finish)
      scalar = 1.0
      peak.each_with_index do |p, i|
        next if p.zero?
        value = normalized_coordinates[i]
        if start
          return 0.0 if value < start[i] || value > finish[i]
          next if value == p
          scalar *= value < p ? (value - start[i]) / (p - start[i]) : (finish[i] - value) / (finish[i] - p)
        else
          return 0.0 if value.zero? || value * p < 0
          scalar *= value / p if value.abs < p.abs
        end
      end
      scalar
    end

    def packed_points(data, maximum)
      count = data.u8
      return nil if count.zero?
      count = ((count & 0x7f) << 8) | data.u8 if count & 0x80 != 0
      points, previous = [], 0
      while points.length < count
        control = data.u8
        run = (control & 0x7f) + 1
        raise InvalidFont, "gvar point run overflow" if points.length + run > count
        run.times do
          previous += control & 0x80 != 0 ? data.u16 : data.u8
          raise InvalidFont, "gvar point out of bounds" if previous >= maximum
          points << previous
        end
      end
      points
    end

    def packed_deltas(data, count)
      result = []
      while result.length < count
        control = data.u8
        length = (control & 0x3f) + 1
        raise InvalidFont, "gvar delta run overflow" if result.length + length > count
        length.times { result << (control & 0x80 != 0 ? 0 : control & 0x40 != 0 ? data.i16 : data.i8) }
      end
      result
    end

    def interpolate_untouched(points, deltas, ends)
      first = 0
      ends.each do |last|
        touched = (first..last).select { |i| deltas[i] }
        if touched.length == 1
          (first..last).each { |i| deltas[i] ||= deltas[touched[0]].dup }
        elsif touched.length > 1
          touched.each_with_index do |a, index|
            b = touched[(index + 1) % touched.length]
            cursor = a == last ? first : a + 1
            while cursor != b
              deltas[cursor] = 2.times.map do |axis|
                c1, c2 = points[a][axis], points[b][axis]
                d1, d2 = deltas[a][axis], deltas[b][axis]
                c1, c2, d1, d2 = c2, c1, d2, d1 if c1 > c2
                value = points[cursor][axis]
                if c1 == c2
                  d1 == d2 ? d1 : 0.0
                elsif value <= c1
                  d1
                elsif value >= c2
                  d2
                else
                  d1 + (d2 - d1) * (value - c1).to_f / (c2 - c1)
                end
              end
              cursor = cursor == last ? first : cursor + 1
            end
          end
        end
        first = last + 1
      end
    end
  end
end
