# frozen_string_literal: true

module Alhena
  # Lazy sfnt/OpenType reader. Does not execute hinting bytecode or shape text.
  class Font
    LOOKUP_CACHE_SIZE = 4096
    private_constant :LOOKUP_CACHE_SIZE
    attr_reader :index, :tables, :axis_values

    # @param path [String] sfnt, OpenType or TTC filename
    # @param index [Integer] zero-based collection face
    # @param axes [Hash] variation axis tags and user-space coordinates
    # @return [Font]
    def self.open(path, index: 0, axes: {}) = new(File.binread(path), index: index, axes: axes)

    def initialize(data, index: 0, axes: {})
      raise ArgumentError, "index must be a nonnegative integer" unless index.is_a?(Integer) && index >= 0
      @binary = Binary.new(data.b.freeze)
      @index = index
      @axis_values = axes.transform_keys(&:to_s).freeze
      offset = 0
      if @binary.bytes(0, 4) == "ttcf"
        count = @binary.u32(8)
        @binary.validate_bounds(12, count * 4)
        raise InvalidFont, "collection index out of range" unless index < count
        offset = @binary.u32(12 + index * 4)
      elsif index != 0
        raise InvalidFont, "collection index out of range"
      end
      signature = @binary.bytes(offset, 4)
      raise UnsupportedFont, "expected sfnt, OpenType or TTC" unless ["\x00\x01\x00\x00".b, "OTTO", "true"].include?(signature)
      count = @binary.u16(offset + 4)
      @binary.validate_bounds(offset + 12, count * 16)
      @tables = {}
      count.times do |i|
        record = offset + 12 + i * 16
        tag = @binary.bytes(record, 4)
        location, length = @binary.u32(record + 8), @binary.u32(record + 12)
        @binary.validate_bounds(location, length)
        raise InvalidFont, "duplicate #{tag} table" if @tables.key?(tag)
        @tables[tag] = [location, length].freeze
      end
      @tables.freeze
      @parsed = {}
      normalized_coordinates unless @axis_values.empty?
    end

    def table(tag)
      @parsed[tag] ||= begin
        location, length = @tables.fetch(tag) { raise InvalidFont, "missing #{tag} table" }
        Binary.new(@binary.bytes(location, length).freeze)
      end
    end
    # Original immutable sfnt/TTC bytes for native rasterizer interoperability.
    def data = @binary.data

    def units_per_em
      value = table("head").u16(18)
      raise InvalidFont, "invalid unitsPerEm" unless (16..16_384).cover?(value)
      value
    end

    def glyph_count = table("maxp").u16(4)
    def ascent = table("hhea").i16(4)
    def descent = table("hhea").i16(6)
    def line_gap = table("hhea").i16(8)

    def names
      @names ||= begin
        data = table("name")
        count, storage = data.u16(2), data.u16(4)
        data.validate_bounds(6, count * 12)
        result = {}
        count.times do |i|
          at = 6 + i * 12
          platform, _encoding, language, name_id, length, offset = 6.times.map { |j| data.u16(at + j * 2) }
          next unless [0, 1, 3].include?(platform)
          text = data.bytes(storage + offset, length)
          text = text.force_encoding(platform == 1 ? "macRoman" : "UTF-16BE").encode("UTF-8", invalid: :replace, undef: :replace)
          priority = platform == 3 && language == 0x409 ? 3 : platform == 0 ? 2 : 1
          result[name_id] = [priority, text.freeze] if !result.key?(name_id) || result[name_id][0] < priority
        end
        result.transform_values(&:last).freeze
      end
    end

    def family = names[16] || names[1]

    def os2
      data = table("OS/2")
      {version: data.u16(0), weight: data.u16(4), width: data.u16(6),
       typo_ascent: data.i16(68), typo_descent: data.i16(70), typo_line_gap: data.i16(72),
       win_ascent: data.u16(74), win_descent: data.u16(76)}.freeze
    end

    def post
      data = table("post")
      {version: data.fixed(0), italic_angle: data.fixed(4), underline_position: data.i16(8),
       underline_thickness: data.i16(10), fixed_pitch: data.u32(12) != 0}.freeze
    end

    # Accept a Unicode scalar or a string, optionally with an explicit selector.
    def glyph_id(character, variation_selector: nil)
      codepoint = character.is_a?(String) ? character.ord : character
      raise ArgumentError, "invalid Unicode scalar" unless codepoint.is_a?(Integer) && (0..0x10ffff).cover?(codepoint) && !(0xd800..0xdfff).cover?(codepoint)
      if variation_selector
        selector = variation_selector.is_a?(String) ? variation_selector.ord : variation_selector
        variant = variation_glyph_mapping(codepoint, selector)
        return variant unless variant == :default
      end
      cache = (@glyph_ids ||= {})
      cached = cache[codepoint]
      return cached if cached
      maps, index, result = cmaps, 0, 0
      while (data = maps[index])
        result = glyph_id_from_cmap(data, codepoint)
        break if result != 0 && result < glyph_count
        index += 1
        result = 0
      end
      cache.shift if cache.length >= LOOKUP_CACHE_SIZE
      cache[codepoint] = result
    end

    def advance(glyph, size: units_per_em, vertical: false)
      cached_metric(glyph, vertical: vertical)[0] * scale_factor(size)
    end

    def bearing(glyph, size: units_per_em, vertical: false)
      cached_metric(glyph, vertical: vertical)[1] * scale_factor(size)
    end

    # @param glyph [Integer] glyph ID, not a Unicode scalar
    # @return [Outline] unhinted path in font units with Y increasing upwards
    def outline(glyph)
      validate_glyph(glyph)
      if @tables.key?("glyf")
        truetype_glyph(glyph, [])[0]
      elsif @tables.key?("CFF ")
        (@cff ||= CFF.new(table("CFF "), units_per_em: units_per_em)).outline(glyph)
      elsif @tables.key?("CFF2")
        (@cff ||= CFF.new(table("CFF2"), units_per_em: units_per_em, coordinates: normalized_coordinates)).outline(glyph)
      else
        raise UnsupportedFont, "font contains no vector outlines"
      end
    end

    def rasterize(glyph, size:, subpixel_x: 0, tolerance: 0.25, gamma: 1.0, darkening: 0.0, lcd: nil)
      factor = scale_factor(size)
      raise ArgumentError, "invalid subpixel position" unless subpixel_x.is_a?(Numeric) && subpixel_x.finite?
      path = outline(glyph).transform([factor, 0, 0, -factor, subpixel_x, 0])
      # Match the conventional 26.6 pixel grid used by font rasterizers.
      path.coordinates.map! { |value| (value * 64).round / 64.0 }
      return Bitmap.new(width: 0, height: 0, coverage: "") if path.empty?
      xmin, ymin, xmax, ymax = path.bounds
      left, top, right, bottom = xmin.floor, ymin.floor, xmax.ceil, ymax.ceil
      padding = lcd ? 1 : 0
      left -= padding
      right += padding
      translated = path.transform([1, 0, 0, 1, -left, -top])
      Rasterizer.new(width: right - left, height: bottom - top, tolerance: tolerance).fill(
        translated, left: left, top: -top, gamma: gamma, darkening: darkening, lcd: lcd
      )
    end

    private

    def scale_factor(size)
      raise ArgumentError, "size must be positive and finite" unless size.is_a?(Numeric) && size.finite? && size > 0
      size.to_f / units_per_em
    end

    def validate_glyph(glyph)
      raise ArgumentError, "glyph ID out of range" unless glyph.is_a?(Integer) && glyph >= 0 && glyph < glyph_count
    end

    # Font bytes and variation coordinates never change. Cache font-unit pairs,
    # not sizes; bound missing-character and large-CJK scans as well as hits.
    def cached_metric(glyph, vertical:)
      validate_glyph(glyph)
      cache = vertical ? (@vertical_metrics ||= {}) : (@horizontal_metrics ||= {})
      cached = cache[glyph]
      return cached if cached
      result = metric(glyph, vertical: vertical).freeze
      cache.shift if cache.length >= LOOKUP_CACHE_SIZE
      cache[glyph] = result
    end

    def raw_metric(glyph, vertical: false)
      validate_glyph(glyph)
      count = table(vertical ? "vhea" : "hhea").u16(34)
      raise InvalidFont, "invalid metric count" unless count > 0 && count <= glyph_count
      data = table(vertical ? "vmtx" : "hmtx")
      width = data.u16([glyph, count - 1].min * 4)
      bearing_offset = glyph < count ? glyph * 4 + 2 : count * 4 + (glyph - count) * 2
      [width, data.i16(bearing_offset)]
    end

    def cmaps
      @cmaps ||= begin
        cmap = table("cmap")
        count = cmap.u16(2)
        cmap.validate_bounds(4, count * 8)
        @variation_cmap = nil
        records = count.times.filter_map do |i|
          platform, encoding = cmap.u16(4 + i * 8), cmap.u16(6 + i * 8)
          next unless platform == 0 || (platform == 3 && [0, 1, 10].include?(encoding)) || (platform == 1 && encoding.zero?)
          offset = cmap.u32(8 + i * 8)
          format = cmap.u16(offset)
          next unless [0, 4, 6, 12, 13, 14].include?(format)
          length = format == 14 ? cmap.u32(offset + 2) : format >= 12 ? cmap.u32(offset + 4) : cmap.u16(offset + 2)
          record = Binary.new(cmap.bytes(offset, length))
          if format == 14
            @variation_cmap = record
            next
          end
          [format == 12 ? 4 : format == 4 ? 3 : platform == 0 ? 2 : 1, record]
        end
        records.sort_by { |priority, _| -priority }.map(&:last)
      end
    end

    def glyph_id_from_cmap(data, code)
      case data.u16(0)
      when 0
        code < 256 ? data.u8(6 + code) : 0
      when 6
        first, count = data.u16(6), data.u16(8)
        code >= first && code < first + count ? data.u16(10 + (code - first) * 2) : 0
      when 4
        return 0 if code > 0xffff
        count = data.u16(6) / 2
        data.validate_bounds(14, count * 8 + 2)
        lo, hi = 0, count
        while lo < hi
          mid = (lo + hi) / 2
          data.u16(14 + mid * 2) < code ? lo = mid + 1 : hi = mid
        end
        return 0 if lo == count
        start = data.u16(16 + count * 2 + lo * 2)
        return 0 if code < start
        delta = data.i16(16 + count * 4 + lo * 2)
        at = 16 + count * 6 + lo * 2
        offset = data.u16(at)
        return (code + delta) & 0xffff if offset.zero?
        glyph = data.u16(at + offset + (code - start) * 2)
        glyph.zero? ? 0 : (glyph + delta) & 0xffff
      when 12, 13
        constant = data.u16(0) == 13
        count = data.u32(12)
        data.validate_bounds(16, count * 12)
        lo, hi = 0, count
        while lo < hi
          mid = (lo + hi) / 2
          data.u32(20 + mid * 12) < code ? lo = mid + 1 : hi = mid
        end
        return 0 if lo == count
        start = data.u32(16 + lo * 12)
        return 0 if code < start
        data.u32(24 + lo * 12) + (constant ? 0 : code - start)
      end
    end

    def variation_glyph_mapping(code, selector)
      cmaps
      return 0 unless @variation_cmap
      data = @variation_cmap
      count = data.u32(6)
      data.validate_bounds(10, count * 11)
      count.times do |i|
        at = 10 + i * 11
        next unless data.u24(at) == selector
        default, nondefault = data.u32(at + 3), data.u32(at + 7)
        unless nondefault.zero?
          entries = data.u32(nondefault)
          data.validate_bounds(nondefault + 4, entries * 5)
          entries.times do |j|
            entry = nondefault + 4 + j * 5
            return data.u16(entry + 3) if data.u24(entry) == code
          end
        end
        unless default.zero?
          entries = data.u32(default)
          data.validate_bounds(default + 4, entries * 4)
          entries.times do |j|
            entry = default + 4 + j * 4
            start = data.u24(entry)
            return :default if code >= start && code <= start + data.u8(entry + 3)
          end
        end
      end
      0
    end

    def truetype_glyph(glyph, ancestors)
      raise InvalidFont, "cyclic or deeply nested composite glyph" if ancestors.include?(glyph) || ancestors.length > 5
      validate_glyph(glyph)
      loca = table("loca")
      format = table("head").i16(50)
      raise InvalidFont, "invalid loca format" unless [0, 1].include?(format)
      first = format.zero? ? loca.u16(glyph * 2) * 2 : loca.u32(glyph * 4)
      last = format.zero? ? loca.u16((glyph + 1) * 2) * 2 : loca.u32((glyph + 1) * 4)
      source = table("glyf")
      data = Binary.new(source.bytes(first, last - first))
      path, points = Outline.new, []
      if data.size.zero?
        vary_points(glyph, [], [], data)
        return [path, points]
      end
      contours = data.i16(0)
      data.validate_bounds(0, 10)
      data.position = 10
      if contours.zero?
        vary_points(glyph, [], [], data)
        return [path, points]
      end
      return simple_glyph(data, contours, glyph) if contours.positive?
      composite_glyph(data, glyph, ancestors)
    end

    def composite_glyph(data, glyph, ancestors)
      components = read_composite_components(data)
      instructions = data.u16 if components.last[0] & 256 != 0
      data.validate_bounds(data.position, instructions) if instructions
      original_offsets = components.map { |flags, _, args, *_| flags & 2 != 0 ? args : [0, 0] }
      offsets = vary_points(glyph, original_offsets, [], data)
      path, points = Outline.new, []
      components.each_with_index do |(flags, child, args, a, b, c, d), component|
        xy = flags & 2 != 0
        child_path, child_points = truetype_glyph(child, ancestors + [glyph])
        transformed = child_points.map { |x, y| [a * x + c * y, b * x + d * y] }
        if xy
          dx, dy = offsets[component]
          dx, dy = a * dx + c * dy, b * dx + d * dy if flags & 0x800 != 0
        else
          parent_point, child_point = points[args[0]], transformed[args[1]]
          raise InvalidFont, "invalid composite point attachment" unless parent_point && child_point
          dx, dy = parent_point[0] - child_point[0], parent_point[1] - child_point[1]
        end
        path.append(child_path.transform([a, b, c, d, dx, dy]))
        points.concat(transformed.map { |x, y| [x + dx, y + dy] })
        raise InvalidFont, "composite glyph exceeds point limit" if points.length > 65_536
      end
      [path, points]
    end

    def read_composite_components(data)
      components = []
      loop do
        flags, child = data.u16, data.u16
        raise InvalidFont, "composite child glyph out of range" if child >= glyph_count
        words, xy = flags & 1 != 0, flags & 2 != 0
        args = 2.times.map { xy ? (words ? data.i16 : data.i8) : (words ? data.u16 : data.u8) }
        a, b, c, d = 1.0, 0.0, 0.0, 1.0
        if flags & 8 != 0
          a = d = data.i16 / 16_384.0
        elsif flags & 64 != 0
          a, d = data.i16 / 16_384.0, data.i16 / 16_384.0
        elsif flags & 128 != 0
          a, b, c, d = 4.times.map { data.i16 / 16_384.0 }
        end
        components << [flags, child, args, a, b, c, d]
        break if flags & 32 == 0
      end
      components
    end

    def simple_glyph(data, count, glyph)
      ends = count.times.map { data.u16 }
      raise InvalidFont, "invalid contour endpoints" unless ends.each_cons(2).all? { |a, b| a < b }
      instructions = data.u16
      data.validate_bounds(data.position, instructions)
      data.position += instructions
      total = ends.last + 1
      flags = []
      while flags.length < total
        flag = data.u8
        repeat = flag & 8 == 0 ? 1 : data.u8 + 1
        raise InvalidFont, "glyph flag repetition overflow" if flags.length + repeat > total
        repeat.times { flags << flag }
      end
      axes = [[2, 16], [4, 32]].map do |short, same|
        value = 0
        flags.map do |flag|
          delta = if flag & short != 0
            data.u8 * (flag & same == 0 ? -1 : 1)
          else
            flag & same == 0 ? data.i16 : 0
          end
          value += delta
        end
      end
      points = axes[0].zip(axes[1])
      points = vary_points(glyph, points, ends, data)
      [simple_glyph_outline(points, flags, ends), points]
    end

    def simple_glyph_outline(points, flags, ends)
      path, first = Outline.new, 0
      ends.each do |last|
        contour = (first..last).map { |i| [*points[i], flags[i] & 1 != 0] }
        start = if contour.first[2]
          contour.shift
        elsif contour.last[2]
          contour.pop
        else
          [(contour.first[0] + contour.last[0]) / 2.0, (contour.first[1] + contour.last[1]) / 2.0, true]
        end
        path.move_to(*start[0, 2])
        contour << start
        pending = nil
        contour.each do |point|
          if point[2]
            pending ? path.quad_to(*pending[0, 2], *point[0, 2]) : path.line_to(*point[0, 2])
            pending = nil
          else
            path.quad_to(*pending[0, 2], (pending[0] + point[0]) / 2.0, (pending[1] + point[1]) / 2.0) if pending
            pending = point
          end
        end
        path.close
        first = last + 1
      end
      path
    end
  end
end
