# frozen_string_literal: true

module Alhena
  # CFF1 INDEX/DICT reader and Type 2 charstring interpreter.
  class CFF
    def initialize(data, units_per_em: 1000, coordinates: [])
      @data, @units_per_em, @coordinates = data, units_per_em, coordinates
      @version = data.u8(0)
      raise UnsupportedFont, "unsupported CFF version" unless [1, 2].include?(@version)
      header_size = data.u8(2)
      raise InvalidFont, "invalid CFF header" if header_size < 4
      if @version == 2
        top_length = data.u16(3)
        @top = parse_dictionary(data.bytes(header_size, top_length))
        @global_subrs, = read_index(header_size + top_length)
        @store = VariationStore.new(data, @top[24].first + 2, coordinates) if @top.key?(24)
      else
        names, at = read_index(header_size)
        tops, at = read_index(at)
        _strings, at = read_index(at)
        @global_subrs, = read_index(at)
        raise InvalidFont, "OpenType CFF must contain one font" unless names.size == 1 && tops.size == 1
        @top = parse_dictionary(tops.first)
      end
      raise UnsupportedFont, "only Type 2 charstrings are supported" unless @top.fetch(1206, [2]).first == 2
      @charstrings, = read_index(@top.fetch(17) { raise InvalidFont, "missing CFF CharStrings" }.first)
      @matrix = @top.fetch(1207, [0.001, 0, 0, 0.001, 0, 0])
      raise InvalidFont, "invalid CFF FontMatrix" unless @matrix.size == 6
      if @top.key?(1230) || @version == 2
        dictionaries, = read_index(@top.fetch(1236).first)
        @privates = dictionaries.map { |entry| read_private_dict(parse_dictionary(entry)) }
        @fd_select = @top[1237]&.first
      else
        @privates = [read_private_dict(@top)]
        @privates.first[3] = nil
      end
    rescue KeyError, TypeError => error
      raise InvalidFont, "invalid CFF dictionary: #{error.message}"
    end

    def outline(glyph)
      raise InvalidFont, "CFF glyph out of range" unless glyph >= 0 && glyph < @charstrings.length
      local, default, nominal, matrix, vsindex = @privates.fetch(font_dict_index(glyph)) { raise InvalidFont, "invalid FDSelect index" }
      interpreter = Charstring.new(local, @global_subrs, default: default, nominal: nominal, version: @version, store: @store, vsindex: vsindex)
      path = interpreter.outline(@charstrings[glyph])
      if matrix
        path = path.transform(matrix)
      end
      path.transform(@matrix.map { |n| n * @units_per_em })
    end

    private

    def read_index(at)
      count_bytes = @version == 2 ? 4 : 2
      count = @version == 2 ? @data.u32(at) : @data.u16(at)
      return [[], at + count_bytes] if count.zero?
      width = @data.u8(at + count_bytes)
      raise InvalidFont, "invalid CFF offSize" unless (1..4).cover?(width)
      @data.validate_bounds(at + count_bytes + 1, (count + 1) * width)
      offsets = (count + 1).times.map do |i|
        value = 0
        width.times { |j| value = (value << 8) | @data.u8(at + count_bytes + 1 + i * width + j) }
        value
      end
      raise InvalidFont, "invalid CFF INDEX offsets" unless offsets.first == 1 && offsets.each_cons(2).all? { |a, b| a <= b }
      start = at + count_bytes + (count + 1) * width
      @data.validate_bounds(start + 1, offsets.last - 1)
      [offsets.each_cons(2).map { |a, b| @data.bytes(start + a, b - a) }, start + offsets.last]
    end

    def parse_dictionary(bytes)
      data, stack, result = Binary.new(bytes), [], {}
      while data.position < data.size
        byte = data.u8
        if byte >= 32 || [28, 29, 30].include?(byte)
          stack << read_number(data, byte)
          raise InvalidFont, "CFF DICT operand overflow" if stack.length > (@version == 2 ? 513 : 48)
        else
          operation = byte == 12 ? 1200 + data.u8 : byte
          if @version == 2 && operation == 23
            self.class.blend(stack, @store, result.fetch(22, [0]).first)
            next
          end
          result[operation] = stack
          stack = []
        end
      end
      raise InvalidFont, "unterminated CFF DICT operands" unless stack.empty?
      result
    end

    def read_number(data, byte)
      case byte
      when 28 then data.i16
      when 29 then data.i32
      when 30
        value = +""
        loop do
          pair = data.u8
          [pair >> 4, pair & 15].each do |nibble|
            return Float(value) if nibble == 15
            raise InvalidFont, "reserved CFF real nibble" if nibble == 13
            value << (nibble < 10 ? nibble.to_s : {10 => ".", 11 => "E", 12 => "E-", 14 => "-"}.fetch(nibble))
            raise InvalidFont, "oversized CFF real" if value.size > 64
          end
        end
      when 32..246 then byte - 139
      when 247..250 then (byte - 247) * 256 + data.u8 + 108
      when 251..254 then -(byte - 251) * 256 - data.u8 - 108
      else raise InvalidFont, "invalid CFF number"
      end
    rescue ArgumentError
      raise InvalidFont, "invalid CFF real"
    end

    def read_private_dict(dict)
      length, offset = dict.fetch(18, [0, 0])
      private_data = parse_dictionary(@data.bytes(offset, length))
      local = private_data.key?(19) ? read_index(offset + private_data[19].first).first : []
      [local, private_data.fetch(20, [0]).first, private_data.fetch(21, [0]).first, dict[1207], private_data.fetch(22, [0]).first]
    end

    def font_dict_index(glyph)
      return 0 unless @fd_select
      case @data.u8(@fd_select)
      when 0
        @data.u8(@fd_select + 1 + glyph)
      when 3
        count = @data.u16(@fd_select + 1)
        @data.validate_bounds(@fd_select + 3, count * 3 + 2)
        count.times do |i|
          at = @fd_select + 3 + i * 3
          first, last = @data.u16(at), @data.u16(at + 3)
          return @data.u8(at + 2) if glyph >= first && glyph < last
        end
        raise InvalidFont, "FDSelect does not cover glyph"
      when 4
        count = @data.u32(@fd_select + 1)
        @data.validate_bounds(@fd_select + 5, count * 6 + 4)
        count.times do |i|
          at = @fd_select + 5 + i * 6
          return @data.u16(at + 4) if glyph >= @data.u32(at) && glyph < @data.u32(at + 6)
        end
        raise InvalidFont, "FDSelect does not cover glyph"
      else
        raise UnsupportedFont, "unsupported CFF FDSelect format"
      end
    end

    def self.blend(stack, store, vsindex)
      raise InvalidFont, "CFF2 blend has no variation store" unless store
      count = stack.pop
      raise InvalidFont, "invalid CFF2 blend count" unless count.is_a?(Numeric) && count == count.to_i && count > 0
      count = count.to_i
      scalars = store.region_scalars(vsindex)
      required = count * (scalars.length + 1)
      raise InvalidFont, "CFF2 blend stack underflow" if required > stack.length
      values = stack.pop(required)
      count.times { |i| stack << values[i] + scalars.each_with_index.sum { |scalar, j| values[count + i * scalars.length + j] * scalar } }
    end

    class Charstring
      attr_reader :width

      def initialize(local, global, default:, nominal:, version: 1, store: nil, vsindex: 0)
        @local, @global, @default, @nominal = local, global, default, nominal
        @version, @store, @vsindex = version, store, vsindex || 0
      end

      def outline(bytes)
        @path, @stack, @transient = Outline.new, [], Array.new(32, 0)
        @x = @y = 0.0
        @stems = @operations = 0
        @width, @ended = @version == 2 ? 0 : nil, false
        execute(Binary.new(bytes), 0)
        if @version == 2
          @path.close unless @path.empty?
          @ended = true
        end
        raise InvalidFont, "CFF charstring missing endchar" unless @ended
        @path
      end

      private

      def execute(data, depth)
        raise InvalidFont, "CFF subroutine depth limit" if depth > 10
        while data.position < data.size && !@ended
          @operations += 1
          raise InvalidFont, "CFF instruction limit" if @operations > 100_000
          byte = data.u8
          if byte >= 32 || byte == 28
            value = case byte
            when 28 then data.i16
            when 32..246 then byte - 139
            when 247..250 then (byte - 247) * 256 + data.u8 + 108
            when 251..254 then -(byte - 251) * 256 - data.u8 - 108
            when 255 then data.fixed
            end
            push(value)
            next
          end
          case byte
          when 1, 3, 18, 23, 19, 20
            read_width(@stack.length.odd?)
            require_operand_groups(2, allow_empty: true)
            @stems += @stack.length / 2
            raise InvalidFont, "CFF hint limit" if @stems > 96
            @stack.clear
            if byte == 19 || byte == 20
              length = (@stems + 7) / 8
              data.validate_bounds(data.position, length)
              data.position += length
            end
          when 4, 21, 22
            count = byte == 21 ? 2 : 1
            read_width(@stack.length > count)
            require_exact_operands(count)
            @path.close unless @path.empty?
            dx, dy = byte == 21 ? @stack : byte == 22 ? [@stack[0], 0] : [0, @stack[0]]
            @x += dx
            @y += dy
            @path.move_to(@x, @y)
            @stack.clear
          when 5
            require_operand_groups(2)
            @stack.each_slice(2) { |dx, dy| line(dx, dy) }
            @stack.clear
          when 6, 7
            require_operand_groups(1)
            horizontal = byte == 6
            @stack.each do |value|
              horizontal ? line(value, 0) : line(0, value)
              horizontal = !horizontal
            end
            @stack.clear
          when 8
            require_operand_groups(6)
            @stack.each_slice(6) { |args| curve(*args) }
            @stack.clear
          when 10, 29
            subrs = byte == 10 ? @local : @global
            bias = subrs.length < 1240 ? 107 : subrs.length < 33_900 ? 1131 : 32_768
            index = pop
            raise InvalidFont, "invalid CFF subroutine index" unless index.is_a?(Integer) && index + bias >= 0 && index + bias < subrs.length
            execute(Binary.new(subrs[index + bias]), depth + 1)
          when 11
            raise InvalidFont, "return outside subroutine" if depth.zero?
            return
          when 12
            execute_escape_operator(data.u8)
          when 14
            read_width(@stack.length == 1 || @stack.length == 5)
            raise UnsupportedFont, "deprecated CFF endchar composites are unsupported" if @stack.length == 4
            require_exact_operands(0)
            @path.close unless @path.empty?
            @ended = true
          when 15
            raise InvalidFont, "vsindex requires CFF2" unless @version == 2
            @vsindex = pop
            raise InvalidFont, "invalid CFF2 vsindex" unless @vsindex.is_a?(Integer) && @vsindex >= 0
          when 16
            raise InvalidFont, "blend requires CFF2" unless @version == 2
            CFF.blend(@stack, @store, @vsindex)
          when 24
            raise InvalidFont, "invalid rcurveline operands" unless @stack.length >= 8 && (@stack.length - 2) % 6 == 0
            @stack[0...-2].each_slice(6) { |args| curve(*args) }
            line(*@stack[-2, 2])
            @stack.clear
          when 25
            raise InvalidFont, "invalid rlinecurve operands" unless @stack.length >= 8 && (@stack.length - 6) % 2 == 0
            @stack[0...-6].each_slice(2) { |args| line(*args) }
            curve(*@stack[-6, 6])
            @stack.clear
          when 26, 27
            extra = @stack.length % 4 == 1 ? @stack.shift : 0
            require_operand_groups(4)
            @stack.each_slice(4) do |a, b, c, d|
              byte == 26 ? curve(extra, a, b, c, 0, d) : curve(a, extra, b, c, d, 0)
              extra = 0
            end
            @stack.clear
          when 30, 31
            horizontal = byte == 31
            raise InvalidFont, "invalid alternating curve operands" unless @stack.length >= 4 && [0, 1].include?(@stack.length % 4)
            until @stack.empty?
              a, b, c, d = @stack.shift(4)
              extra = @stack.length == 1 ? @stack.shift : 0
              horizontal ? curve(a, 0, b, c, extra, d) : curve(0, a, b, c, d, extra)
              horizontal = !horizontal
            end
          else
            raise InvalidFont, "unsupported CFF operator #{byte}"
          end
        end
      end

      def push(value)
        raise InvalidFont, "CFF stack overflow or nonfinite value" if @stack.length >= (@version == 2 ? 513 : 48) || !value.finite? || value.abs > 1e12
        @stack << value
      end

      def pop
        @stack.pop || raise(InvalidFont, "CFF stack underflow")
      end

      def require_exact_operands(count)
        raise InvalidFont, "CFF expected #{count} operands, got #{@stack.length}" unless @stack.length == count
      end

      def require_operand_groups(size, allow_empty: false)
        raise InvalidFont, "invalid CFF operand count" if (!allow_empty && @stack.empty?) || @stack.length % size != 0
      end

      def read_width(present)
        return unless @width.nil?
        @width = present ? @stack.shift + @nominal : @default
      end

      def line(dx, dy)
        raise InvalidFont, "CFF path has no moveto" if @path.empty?
        @x += dx
        @y += dy
        @path.line_to(@x, @y)
      end

      def curve(dx1, dy1, dx2, dy2, dx3, dy3)
        raise InvalidFont, "CFF path has no moveto" if @path.empty?
        x1, y1 = @x + dx1, @y + dy1
        x2, y2 = x1 + dx2, y1 + dy2
        @x, @y = x2 + dx3, y2 + dy3
        @path.cubic_to(x1, y1, x2, y2, @x, @y)
      end

      def execute_escape_operator(operator)
        case operator
        when 0 then nil # obsolete dotsection
        when 3, 4, 10, 11, 12, 15, 24
          b, a = pop, pop
          result = case operator
          when 3 then !a.zero? && !b.zero? ? 1 : 0
          when 4 then !a.zero? || !b.zero? ? 1 : 0
          when 10 then a + b
          when 11 then a - b
          when 12
            raise InvalidFont, "CFF division by zero" if b.zero?
            a.to_f / b
          when 15 then a == b ? 1 : 0
          when 24 then a * b
          end
          push(result)
        when 5 then push(pop.zero? ? 1 : 0)
        when 9 then push(pop.abs)
        when 14 then push(-pop)
        when 18 then pop
        when 20
          index, value = pop, pop
          raise InvalidFont, "invalid CFF transient index" unless index.is_a?(Integer) && (0...32).cover?(index)
          @transient[index] = value
        when 21
          index = pop
          raise InvalidFont, "invalid CFF transient index" unless index.is_a?(Integer) && (0...32).cover?(index)
          push(@transient[index])
        when 22
          v2, v1, s2, s1 = pop, pop, pop, pop
          push(v1 <= v2 ? s1 : s2)
        when 23
          # Deterministic local PRNG; no process-global random state.
          @random = ((@random || 1) * 1_103_515_245 + 12_345) & 0x7fffffff
          push((@random + 1) / 2_147_483_649.0)
        when 26
          value = pop
          raise InvalidFont, "CFF square root of negative operand" if value < 0
          push(Math.sqrt(value))
        when 27
          value = pop
          push(value)
          push(value)
        when 28
          b, a = pop, pop
          push(b)
          push(a)
        when 29
          index = pop
          raise InvalidFont, "invalid CFF index operand" unless index.is_a?(Integer) && !@stack.empty?
          push(@stack[-1 - [[index, 0].max, @stack.length - 1].min])
        when 30
          shift, count = pop, pop
          raise InvalidFont, "invalid CFF roll operands" unless count.is_a?(Integer) && shift.is_a?(Integer) && count >= 0 && count <= @stack.length
          @stack.concat(@stack.pop(count).rotate(-shift)) if count > 0
        when 34
          require_exact_operands(7)
          a, b, c, d, e, f, g = @stack
          curve(a, 0, b, c, d, 0)
          curve(e, 0, f, -c, g, 0)
          @stack.clear
        when 35
          require_exact_operands(13)
          curve(*@stack[0, 6])
          curve(*@stack[6, 6])
          @stack.clear
        when 36
          require_exact_operands(9)
          a, b, c, d, e, f, g, h, i = @stack
          curve(a, b, c, d, e, 0)
          curve(f, 0, g, h, i, -(b + d + h))
          @stack.clear
        when 37
          require_exact_operands(11)
          dx = [0, 2, 4, 6, 8].sum { |i| @stack[i] }
          dy = [1, 3, 5, 7, 9].sum { |i| @stack[i] }
          last = @stack[10]
          curve(*@stack[0, 6])
          curve(*@stack[6, 4], dx.abs > dy.abs ? last : -dx, dx.abs > dy.abs ? -dy : last)
          @stack.clear
        else
          raise InvalidFont, "unsupported CFF escape operator #{operator}"
        end
      end
    end
  end
end
