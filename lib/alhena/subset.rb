# frozen_string_literal: true

module Alhena
  module Subset
    CHECKSUM = 0xb1b0afba
    private_constant :CHECKSUM

    module_function

    def build(font, glyph_ids)
      raise ArgumentError, "font must be an Alhena::Font" unless font.is_a?(Font)
      raise ArgumentError, "glyph_ids must be an Array" unless glyph_ids.is_a?(Array)
      glyph_ids.each do |glyph|
        raise ArgumentError, "glyph ID out of range" unless glyph.is_a?(Integer) && glyph.between?(0, font.glyph_count - 1)
      end

      return cff(font, glyph_ids) if font.cff?

      true_type(font, glyph_ids)
    end

    # Returns a CID-keyed CFF1 program with glyph order matching the requested CIDs.
    # Unlike #build, glyph_ids may repeat; entry zero must be glyph 0 (.notdef).
    def build_cid(font, glyph_ids)
      raise ArgumentError, "font must be an Alhena::Font" unless font.is_a?(Font)
      raise ArgumentError, "glyph_ids must be an Array" unless glyph_ids.is_a?(Array)
      glyph_ids.each do |glyph|
        raise ArgumentError, "glyph ID out of range" unless glyph.is_a?(Integer) && glyph.between?(0, font.glyph_count - 1)
      end
      raise UnsupportedFont, "CID conversion requires a non-variable CFF1 font" unless font.tables.key?("CFF ") && !font.tables.key?("CFF2") && !font.tables.key?("fvar") && !font.tables.key?("HVAR")

      CFF.new(font.table("CFF "), units_per_em: font.units_per_em).subset_cid(glyph_ids)
    end

    def cff(font, glyph_ids)
      raise UnsupportedFont, "CFF2 subsetting is unsupported" unless font.tables.key?("CFF ") && !font.tables.key?("CFF2")
      raise UnsupportedFont, "variable CFF1 subsetting is unsupported" if font.tables.key?("fvar") || font.tables.key?("HVAR")

      glyphs = [0, *glyph_ids].uniq.sort
      remap = glyphs.each_with_index.to_h
      header = font.table("hhea").data.dup
      header[34, 2] = [glyphs.length].pack("n")
      maximum = font.table("maxp").data.dup
      maximum[4, 2] = [glyphs.length].pack("n")
      tables = {
        "CFF " => CFF.new(font.table("CFF "), units_per_em: font.units_per_em).subset(glyphs),
        "head" => font.table("head").data,
        "hhea" => header,
        "hmtx" => metrics(font, glyphs),
        "maxp" => maximum,
        "cmap" => unicode_cmap(font, remap)
      }
      %w[OS/2 name].each { |tag| tables[tag] = font.table(tag).data if font.tables.key?(tag) }
      if font.tables.key?("post")
        post = font.table("post").bytes(0, 32).dup
        post[0, 4] = [0x0003_0000].pack("N")
        tables["post"] = post
      end
      sfnt(font, tables)
    end

    def true_type(font, glyph_ids)
      glyphs = closure(font, [0, *glyph_ids].uniq)
      remap = glyphs.each_with_index.to_h
      glyf, locations = +"".b, [0]
      glyphs.each do |glyph|
        data = remap_components(glyph_bytes(font, glyph), remap)
        glyf << data
        glyf << "\0" if glyf.bytesize.odd?
        locations << glyf.bytesize
      end

      head = font.table("head").data.dup
      head[8, 4] = "\0" * 4
      head[50, 2] = [1].pack("s>")
      hhea = font.table("hhea").data.dup
      hhea[34, 2] = [glyphs.length].pack("n")
      maxp = font.table("maxp").data.dup
      maxp[4, 2] = [glyphs.length].pack("n")
      tables = {"head" => head, "hhea" => hhea, "maxp" => maxp, "glyf" => glyf,
                "loca" => locations.pack("N*"), "hmtx" => metrics(font, glyphs),
                "cmap" => unicode_cmap(font, remap)}
      %w[OS/2 name post].each { |tag| tables[tag] = font.table(tag).data if font.tables.key?(tag) }
      sfnt(font, tables)
    end

    def closure(font, roots)
      found, pending = {}, roots.dup
      until pending.empty?
        glyph = pending.pop
        next if found[glyph]
        found[glyph] = true
        composite_children(glyph_bytes(font, glyph)).each { |child| pending << child unless found[child] }
      end
      found.keys.sort
    end

    def glyph_bytes(font, glyph)
      loca = font.table("loca")
      format = font.table("head").i16(50)
      first = format.zero? ? loca.u16(glyph * 2) * 2 : loca.u32(glyph * 4)
      last = format.zero? ? loca.u16((glyph + 1) * 2) * 2 : loca.u32((glyph + 1) * 4)
      raise InvalidFont, "invalid glyph location" if last < first

      font.table("glyf").bytes(first, last - first)
    end

    def composite_children(data)
      composite_offsets(data).map { |offset| data.unpack1("n", offset: offset) }
    end

    def remap_components(data, remap)
      composite_offsets(data).each do |offset|
        old = data.unpack1("n", offset: offset)
        data[offset, 2] = [remap.fetch(old) { raise InvalidFont, "missing composite glyph #{old}" }].pack("n")
      end
      data
    end

    def composite_offsets(data)
      return [] if data.empty? || data.unpack1("s>") >= 0

      offsets = []
      at = 10
      loop do
        raise InvalidFont, "truncated composite glyph" if at + 4 > data.bytesize
        flags = data.unpack1("n", offset: at)
        offsets << at + 2
        at += 4 + ((flags & 1).zero? ? 2 : 4)
        at += if (flags & 8) != 0 then 2 elsif (flags & 64) != 0 then 4 elsif (flags & 128) != 0 then 8 else 0 end
        break if (flags & 32).zero?
      end
      offsets
    end

    def metrics(font, glyphs)
      glyphs.map { |glyph| [font.advance(glyph).round, font.bearing(glyph).round].pack("ns>") }.join.b
    end

    def unicode_cmap(font, remap)
      entries = font.cmap.filter_map { |codepoint, glyph| [codepoint, remap[glyph]] if remap.key?(glyph) }
      groups = []
      entries.sort.each do |codepoint, glyph|
        previous = groups.last
        if previous && codepoint == previous[1] + 1 && glyph == previous[2] + codepoint - previous[0]
          previous[1] = codepoint
        else
          groups << [codepoint, codepoint, glyph]
        end
      end
      subtable = [12, 0, 16 + groups.length * 12, 0, groups.length].pack("nnNNN") + groups.flatten.pack("N*")
      [0, 1, 0, 4, 12].pack("n4N") + subtable
    end

    def sfnt(font, tables)
      tables = tables.transform_values(&:b)
      head = tables.fetch("head").dup
      head[8, 4] = "\0" * 4
      tables["head"] = head
      count = tables.length
      power = 1 << (Math.log2(count).floor)
      search_range = power * 16
      directory = [font.sfnt_signature, count, search_range, Math.log2(power).to_i, count * 16 - search_range].pack("a4n4")
      payload, records, head_offset = +"".b, +"".b, nil
      tables.sort.each do |tag, bytes|
        offset = 12 + count * 16 + payload.bytesize
        checksum = table_checksum(bytes)
        records << tag << [checksum, offset, bytes.bytesize].pack("N3")
        head_offset = offset if tag == "head"
        payload << bytes
        payload << "\0" until payload.bytesize % 4 == 0
      end
      output = directory + records + payload
      adjustment = (CHECKSUM - table_checksum(output)) & 0xffffffff
      output[head_offset + 8, 4] = [adjustment].pack("N")
      output
    end

    def table_checksum(bytes)
      padded = bytes.dup
      padded << "\0" until padded.bytesize % 4 == 0
      padded.unpack("N*").sum & 0xffffffff
    end
  end
end
