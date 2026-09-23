# frozen_string_literal: true

module Alhena
  class CFF
    class Subsetter
      def initialize(glyphs, data:, version:, top:, top_dictionary_entries:, name_objects:, strings:,
                     global_subrs:, charstrings:, private_records:)
        @glyphs, @data, @version, @top = glyphs, data, version, top
        @top_dictionary_entries, @name_objects, @strings = top_dictionary_entries, name_objects, strings
        @global_subrs, @charstrings, @private_records = global_subrs, charstrings, private_records
      end

      def build
        raise UnsupportedFont, "CFF subsetting requires CFF1" unless @version == 1
        raise UnsupportedFont, "CID-keyed CFF subsetting is unsupported" if @top.key?(1230) || @top.key?(1236) || @top.key?(1237)
        raise UnsupportedFont, "CFF predefined charsets cannot be subset" if @top.fetch(15, [0]).first < 3
        raise UnsupportedFont, "custom CFF encodings cannot be subset" if @top.fetch(16, [0]).first > 1
        raise ArgumentError, "glyphs must be a nonempty Array" unless @glyphs.is_a?(Array) && !@glyphs.empty?
        raise ArgumentError, "CFF glyph out of range" unless @glyphs.all? { |glyph| glyph.is_a?(Integer) && glyph.between?(0, @charstrings.length - 1) }

        glyphs = @glyphs.uniq.sort
        raise ArgumentError, "CFF subset must include glyph 0" unless glyphs.first.zero?
        private_record = @private_records.first
        name_index, string_index = encode_index(@name_objects), encode_index(@strings)
        global_subrs_index = encode_index(@global_subrs)
        charstrings_index = encode_index(glyphs.map { |glyph| @charstrings.fetch(glyph) })
        charset = subset_charset(glyphs)
        local_subrs = private_record ? private_record[:subrs] : []
        has_local_subrs = private_record && private_record[:entries].any? { |operator, _| operator == 19 }
        local_subrs_index = has_local_subrs ? encode_index(local_subrs) : "".b
        private_dictionary = encode_private_dictionary(private_record, has_local_subrs)
        header = @data.bytes(0, @data.u8(2))
        base_offset = header.bytesize + name_index.bytesize + string_index.bytesize + global_subrs_index.bytesize
        charset_offset = charstrings_offset = private_offset = 0

        12.times do
          top_index = encode_index([encode_top_dictionary(charset_offset, charstrings_offset, private_offset, private_dictionary.bytesize)])
          offsets = [base_offset + top_index.bytesize]
          offsets << offsets[0] + charset.bytesize
          offsets << offsets[1] + charstrings_index.bytesize
          break if offsets == [charset_offset, charstrings_offset, private_offset]

          charset_offset, charstrings_offset, private_offset = offsets
        end

        top_index = encode_index([encode_top_dictionary(charset_offset, charstrings_offset, private_offset, private_dictionary.bytesize)])
        offsets = [base_offset + top_index.bytesize]
        offsets << offsets[0] + charset.bytesize
        offsets << offsets[1] + charstrings_index.bytesize
        raise InvalidFont, "CFF subset offsets did not converge" unless offsets == [charset_offset, charstrings_offset, private_offset]

        header + name_index + top_index + string_index + global_subrs_index + charset +
          charstrings_index + private_dictionary + local_subrs_index
      end

      def build_cid
        raise UnsupportedFont, "CFF CID conversion requires name-keyed CFF1" unless @version == 1 && !@top.key?(1230) && !@top.key?(1236) && !@top.key?(1237)
        raise ArgumentError, "glyphs must be a nonempty Array" unless @glyphs.is_a?(Array) && !@glyphs.empty?
        raise ArgumentError, "CFF glyph out of range" unless @glyphs.all? { |glyph| glyph.is_a?(Integer) && glyph.between?(0, @charstrings.length - 1) }
        raise ArgumentError, "CID 0 must map to glyph 0" unless @glyphs.first.zero?
        raise ArgumentError, "CID font cannot exceed 65,536 glyphs" if @glyphs.length > 65_536

        private_record = @private_records.first
        has_local_subrs = private_record && private_record[:entries].any? { |operator, _| operator == 19 }
        private_dictionary = private_record ? encode_private_dictionary(private_record, has_local_subrs) : "".b
        local_subrs_index = has_local_subrs ? encode_index(private_record[:subrs]) : "".b
        charset = [0].pack("C") + (1...@glyphs.length).to_a.pack("n*")
        charstrings_index = encode_index(@glyphs.map { |glyph| @charstrings.fetch(glyph) })
        fd_select = "\0".b * (@glyphs.length + 1)
        header = @data.bytes(0, @data.u8(2))
        name_index = encode_index(@name_objects)
        string_index = encode_index(@strings + ["Adobe", "Identity"])
        global_subrs_index = encode_index(@global_subrs)
        base_offset = header.bytesize + name_index.bytesize + string_index.bytesize + global_subrs_index.bytesize
        offsets = Array.new(5, 0)

        16.times do
          top_index = encode_index([encode_cid_top_dictionary(offsets)])
          cursor = base_offset + top_index.bytesize
          charset_offset = cursor
          cursor += charset.bytesize
          charstrings_offset = cursor
          cursor += charstrings_index.bytesize
          fd_select_offset = cursor
          cursor += fd_select.bytesize
          fd_array_offset = cursor
          fd_dictionary = encode_dictionary([], private_record ? {18 => [private_dictionary.bytesize, offsets[4]]} : {})
          fd_array = encode_index([fd_dictionary])
          private_offset = fd_array_offset + fd_array.bytesize
          current = [charset_offset, charstrings_offset, fd_select_offset, fd_array_offset, private_offset]
          break if current == offsets

          offsets = current
        end

        top_index = encode_index([encode_cid_top_dictionary(offsets)])
        fd_dictionary = encode_dictionary([], private_record ? {18 => [private_dictionary.bytesize, offsets[4]]} : {})
        fd_array = encode_index([fd_dictionary])
        charset_offset, charstrings_offset, fd_select_offset, fd_array_offset, private_offset = offsets
        cursor = base_offset + top_index.bytesize
        expected = [cursor, cursor + charset.bytesize,
          cursor + charset.bytesize + charstrings_index.bytesize,
          cursor + charset.bytesize + charstrings_index.bytesize + fd_select.bytesize]
        raise InvalidFont, "CFF CID subset offsets did not converge" unless expected == offsets.take(4) && fd_array_offset + fd_array.bytesize == private_offset

        header + name_index + top_index + string_index + global_subrs_index + charset +
          charstrings_index + fd_select + fd_array + private_dictionary + local_subrs_index
      end

      private

      def encode_private_dictionary(record, has_subrs)
        return "".b unless record
        return encode_dictionary(record[:entries], {}) unless has_subrs

        relative_offset = 0
        8.times do
          bytes = encode_dictionary(record[:entries], {19 => [relative_offset]})
          return bytes if bytes.bytesize == relative_offset

          relative_offset = bytes.bytesize
        end
        raise InvalidFont, "CFF private subroutine offset did not converge"
      end

      def encode_dictionary(entries, replacements)
        present = {}
        output = +"".b
        entries.each do |operator, operands|
          if replacements.key?(operator)
            output << replacements.fetch(operator).map { |value| encode_number(value) }.join.b
            present[operator] = true
          else
            operands.each { |raw, _value| output << raw }
          end
          output << encode_operator(operator)
        end
        replacements.each do |operator, values|
          next if present[operator]

          output << values.map { |value| encode_number(value) }.join.b
          output << encode_operator(operator)
        end
        output
      end

      def encode_operator(operator)
        operator >= 1200 ? [12, operator - 1200].pack("C2") : [operator].pack("C")
      end

      def encode_number(value)
        raise InvalidFont, "invalid CFF offset" unless value.is_a?(Integer) && value >= 0
        case value
        when 0..107 then [value + 139].pack("C")
        when 108..1131 then [247 + (value - 108) / 256, (value - 108) % 256].pack("C2")
        when 1132..32767 then [28, value].pack("Cn")
        when 32768..0x7fff_ffff then [29, value].pack("CN")
        else raise InvalidFont, "CFF offset exceeds DICT integer range"
        end
      end

      def encode_index(objects)
        raise UnsupportedFont, "too many CFF INDEX entries" if objects.length > 0xffff
        return [0].pack("n") if objects.empty?

        offsets = [1]
        objects.each { |object| offsets << offsets.last + object.bytesize }
        raise UnsupportedFont, "CFF INDEX exceeds 32-bit offsets" if offsets.last > 0xffff_ffff
        width = offsets.last <= 0xff ? 1 : offsets.last <= 0xffff ? 2 : offsets.last <= 0xff_ffff ? 3 : 4
        encoded_offsets = offsets.map do |offset|
          width.times.map { |index| (offset >> ((width - index - 1) * 8)) & 0xff }.pack("C*")
        end.join.b
        [objects.length].pack("n") + [width].pack("C") + encoded_offsets + objects.join.b
      end

      def subset_charset(glyphs)
        offset = @top.fetch(15).first
        format = @data.u8(offset)
        source_sids = [0]
        glyph = 1
        case format
        when 0
          @data.validate_bounds(offset + 1, (@charstrings.length - 1) * 2)
          source_sids.concat((@charstrings.length - 1).times.map { |index| @data.u16(offset + 1 + index * 2) })
        when 1, 2
          cursor = offset + 1
          while glyph < @charstrings.length
            first = @data.u16(cursor)
            cursor += 2
            left = format == 1 ? @data.u8(cursor) : @data.u16(cursor)
            cursor += format == 1 ? 1 : 2
            (left + 1).times { |index| source_sids[glyph] = first + index; glyph += 1 }
            raise InvalidFont, "CFF charset range exceeds glyph count" if glyph > @charstrings.length
          end
        else
          raise UnsupportedFont, "unsupported CFF charset format"
        end
        raise InvalidFont, "CFF charset does not cover glyphs" unless source_sids.length == @charstrings.length

        selected_sids = glyphs.drop(1).map { |glyph_id| source_sids.fetch(glyph_id) }
        unless selected_sids.all? { |sid| sid.between?(0, 390) || (sid >= 391 && sid - 391 < @strings.length) }
          raise InvalidFont, "CFF charset references an invalid SID"
        end
        [0].pack("C") + selected_sids.pack("n*")
      end

      def encode_top_dictionary(charset_offset, charstrings_offset, private_offset, private_size)
        replacements = {15 => [charset_offset], 17 => [charstrings_offset]}
        replacements[18] = [private_size, private_offset] if @top.key?(18)
        replacements[16] = [@top.fetch(16, [0]).first] if @top.key?(16)
        encode_dictionary(@top_dictionary_entries, replacements)
      end

      def encode_cid_top_dictionary(offsets)
        charset_offset, charstrings_offset, fd_select_offset, fd_array_offset = offsets
        entries = @top_dictionary_entries.reject { |operator, _| [15, 16, 17, 18, 1230, 1236, 1237].include?(operator) }
        ros_registry = 391 + @strings.length
        replacements = {15 => [charset_offset], 17 => [charstrings_offset],
          1230 => [ros_registry, ros_registry + 1, 0], 1236 => [fd_array_offset], 1237 => [fd_select_offset]}
        encode_dictionary(entries, replacements)
      end
    end
  end
end
