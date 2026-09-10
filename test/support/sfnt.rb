# frozen_string_literal: true

module SfntFixture
  # Repack table data for surgical malformed-font and format tests.
  def sfnt_with(face, replacements)
    tables = face.tables.to_h { |name, _| [name, replacements.fetch(name) { face.table(name).data }] }.merge(replacements)
    offset = 12 + tables.size * 16
    directory = [0x10000, tables.size, 0, 0, 0].pack("Nn4")
    payload = +"".b
    tables.each do |name, bytes|
      directory << name << [0, offset + payload.bytesize, bytes.bytesize].pack("N3")
      payload << bytes
      payload << "\0" until payload.bytesize % 4 == 0
    end
    directory + payload
  end

  def cmap_table(subtable, platform: 0, encoding: 4)
    [0, 1, platform, encoding, 12].pack("n4N") + subtable
  end
end
