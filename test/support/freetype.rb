# frozen_string_literal: true

require "fiddle/import"

# Development oracle only. Native structure layout is calculated by Fiddle.
module FreeTypeOracle
  extend Fiddle::Importer
  candidates = [ENV["FREETYPE_LIBRARY"], "libfreetype.so.6", "/opt/homebrew/lib/libfreetype.6.dylib",
                "/usr/local/lib/libfreetype.6.dylib", "libfreetype-6.dll"].compact
  library = candidates.find do |path|
    Fiddle.dlopen(path)
  rescue Fiddle::DLError
    false
  end
  raise LoadError, "FreeType is not installed" unless library

  dlload library
  extern "int FT_Init_FreeType(void*)"
  extern "int FT_Done_FreeType(void*)"
  extern "int FT_New_Face(void*, char*, long, void*)"
  extern "int FT_Done_Face(void*)"
  extern "int FT_Set_Pixel_Sizes(void*, unsigned int, unsigned int)"
  extern "int FT_Load_Glyph(void*, unsigned int, int)"
  extern "int FT_Render_Glyph(void*, int)"
  extern "unsigned int FT_Get_Char_Index(void*, unsigned long)"
  extern "void FT_Set_Transform(void*, void*, void*)"
  extern "int FT_Set_Var_Design_Coordinates(void*, unsigned int, void*)"

  def self.set_axes(face, values)
    raise_on_error FT_Set_Var_Design_Coordinates(face, values.length, values.map { |v| (v * 65536).round }.pack("l!*"))
  end

  Face = struct ["long num_faces", "long face_index", "long face_flags", "long style_flags", "long num_glyphs",
                 "void* family_name", "void* style_name", "int num_fixed_sizes", "void* available_sizes",
                 "int num_charmaps", "void* charmaps", "void* generic_data", "void* generic_finalizer",
                 "long bbox[4]", "unsigned short units_per_em", "short ascender", "short descender",
                 "short height", "short max_advance_width", "short max_advance_height",
                 "short underline_position", "short underline_thickness", "void* glyph"]
  Slot = struct ["void* library", "void* face", "void* next", "unsigned int glyph_index",
                 "void* generic_data", "void* generic_finalizer", "long metrics[8]",
                 "long linear_hori_advance", "long linear_vert_advance", "long advance[2]", "unsigned int format",
                 *(Fiddle::SIZEOF_VOIDP == 8 ? ["unsigned int bitmap_alignment"] : []),
                 "unsigned int rows", "unsigned int width", "int pitch", "void* buffer",
                 "unsigned short num_grays", "unsigned char pixel_mode", "unsigned char palette_mode",
                 "void* palette", "int bitmap_left", "int bitmap_top", "short contours", "short points_count",
                 "void* points", "void* tags", "void* contour_ends", "int outline_flags"]

  def self.raise_on_error(code)
    raise "FreeType error #{code}" unless code.zero?
  end

  def self.with_face(path, index: 0)
    library_out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
    face_out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
    raise_on_error FT_Init_FreeType(library_out)
    library = library_out[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
    begin
      raise_on_error FT_New_Face(library, path, index, face_out)
      face = face_out[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
      begin
        yield Face.new(face)
      ensure
        FT_Done_Face(face)
      end
    ensure
      FT_Done_FreeType(library)
    end
  end

  def self.rasterize(face, glyph, size:, subpixel_x: 0)
    raise_on_error FT_Set_Pixel_Sizes(face, 0, size)
    FT_Set_Transform(face, nil, [(subpixel_x * 64).round, 0].pack("l!2"))
    raise_on_error FT_Load_Glyph(face, glyph, 2 | 8) # NO_HINTING | NO_BITMAP
    raise_on_error FT_Render_Glyph(face.glyph, 0)
    slot = Slot.new(face.glyph)
    coverage = String.new(encoding: Encoding::BINARY)
    slot.rows.times do |row|
      offset = slot.pitch.negative? ? (slot.rows - 1 - row) * -slot.pitch : row * slot.pitch
      coverage << slot.buffer[offset, slot.width] if slot.width.positive?
    end
    Alhena::Bitmap.new(width: slot.width, height: slot.rows, left: slot.bitmap_left,
                         top: slot.bitmap_top, coverage: coverage)
  end

  def self.color_bitmap(face, glyph, size:)
    raise_on_error FT_Set_Pixel_Sizes(face, 0, size)
    FT_Set_Transform(face, nil, nil)
    raise_on_error FT_Load_Glyph(face, glyph, (1 << 20) | 2) # COLOR | NO_HINTING
    slot = Slot.new(face.glyph)
    raise_on_error FT_Render_Glyph(face.glyph, 0) unless slot.pixel_mode == 7
    slot = Slot.new(face.glyph)
    raise "FreeType did not return BGRA" unless slot.pixel_mode == 7
    rgba = +"".b
    slot.rows.times do |row|
      slot.buffer[row * slot.pitch, slot.width * 4].bytes.each_slice(4) do |blue, green, red, alpha|
        [red, green, blue].each { |c| rgba << (alpha.zero? ? 0 : (c * 255.0 / alpha).round.clamp(0, 255)) }
        rgba << alpha
      end
    end
    Alhena::ColorBitmap.new(width: slot.width, height: slot.rows, left: slot.bitmap_left, top: slot.bitmap_top, rgba: rgba)
  end
end
