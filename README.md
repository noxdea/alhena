<div align="center">
  <h1>Alhena</h1>
  <p><strong>Pure Ruby TrueType/OpenType/TTC font rasterization with antialiased glyph bitmaps</strong></p>
  <p>
    <a href="https://rubygems.org/gems/alhena"><img src="https://img.shields.io/gem/v/alhena.svg?colorB=319e8c" alt="Gem Version"></a>
    <a href="https://rubygems.org/gems/alhena"><img src="https://img.shields.io/gem/dt/alhena.svg" alt="Downloads"></a>
    <a href="https://github.com/noxdea/alhena/actions/workflows/main.yml"><img src="https://github.com/noxdea/alhena/actions/workflows/main.yml/badge.svg" alt="CI"></a>
    <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-ruby.svg" alt="Ruby Version">
    <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
  </p>
</div>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#supported-formats">Supported Formats</a> ·
  <a href="#development">Development</a>
</p>

---

Alhena reads TrueType, OpenType, and TTC fonts, extracts their outlines, and rasterizes antialiased grayscale, LCD, and color glyph bitmaps. It requires Ruby 3.1+ and has no runtime gem dependencies or native extensions.

## Features

- TrueType, OpenType CFF1/CFF2, and TTC font parsing
- Analytic grayscale and LCD rasterization with subpixel positioning
- Variable font axes, outlines, and metrics
- COLR/CPAL, sbix, and CBDT/CBLC color glyphs
- Entry- and byte-bounded LRU glyph cache
- Lazy, bounds-checked table parsing
- RBS type signatures

## Installation

Add Alhena to your Gemfile:

```ruby
gem "alhena"
```

Then run:

```sh
bundle install
```

Or install it directly:

```sh
gem install alhena
```

## Quick Start

```ruby
require "alhena"

font = Alhena::Font.open("/path/to/font.ttf")
glyph = font.glyph_id("A")
bitmap = font.rasterize(glyph, size: 24)

puts font.family
puts bitmap.to_ascii
```

`bitmap.coverage` is an immutable binary String. Grayscale bitmaps contain one coverage byte per pixel; LCD bitmaps contain three. `width`, `height`, `left`, and `top` describe the bitmap and its bearing. Advances are separate:

```ruby
advance = font.advance(glyph, size: 24)
```

## Usage

### Fonts and metrics

`Font.open(path, index: 0)` reads a font file. `Font.new(bytes, index: 0)` accepts font bytes directly. Tables are parsed on demand.

Metadata methods include `family`, `names`, `units_per_em`, `ascent`, `descent`, `line_gap`, `glyph_count`, `os2`, and `post`. `advance` and `bearing` accept `vertical: true`. `glyph_id` accepts a character or Unicode scalar and an optional `variation_selector:`; unmapped characters return glyph 0.

### Outlines and rasterization

```ruby
outline = font.outline(glyph) # font coordinates, Y up
outline.each { |operation, *coordinates| p [operation, coordinates] }

path = Alhena::Outline.new
path.move_to(0, 0).quad_to(50, 100, 100, 0).close
bitmap = Alhena::Rasterizer.new(width: 100, height: 100).fill(path)
```

`Outline` supports lines, quadratic and cubic curves, transforms, bounds, appending, and cubic-to-quadratic conversion. `Rasterizer#fill` uses pixel coordinates with Y down and implicitly closes open subpaths.

`Font#rasterize` and `Rasterizer#fill` accept `gamma:`, `darkening:`, and `lcd: :rgb` or `:bgr`. Use grayscale when the display subpixel order is unknown.

### Glyph cache

```ruby
cache = Alhena::Cache.new(capacity: 4096, max_bytes: 16 * 1024 * 1024)
cache.prewarm(font, "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", size: 24)
bitmap = cache.rasterize(font, glyph, size: 24, subpixel_x: 0.25)
```

The cache quantizes horizontal positions to quarter pixels and evicts least-recently-used entries. Cache and rasterizer instances are intended for one owner; protect shared instances or use one per thread.

### Variable fonts

```ruby
font.axes
bold = font.variation(wght: 700, wdth: 90)
```

You can also pass axes to `Font.open(path, axes: {wght: 700})`. Unspecified axes use their defaults, and out-of-range values are clamped.

### Color glyphs

```ruby
color = font.color_bitmap(glyph, size: 48, palette: 0)
rgba = color&.rgba
```

`ColorBitmap#rgba` stores straight sRGB RGBA8 pixels, and `to_bitmap` extracts alpha coverage. `Font#rasterize` automatically returns alpha coverage for supported color glyphs. `embedded_bitmap` exposes original sbix/CBDT image data and strike metrics.

## Supported Formats

- sfnt TrueType, OpenType CFF1/CFF2, and TTC collections
- Unicode `cmap` formats 0, 4, 6, 12, 13, and 14
- Simple and composite `glyf` outlines with short or long `loca`
- Type 2 charstrings, CID CFF, variation stores, and CFF2 blends
- `fvar`, `gvar`, `avar` v1, HVAR, and VVAR variable font data
- COLR/CPAL v0, sbix PNG, and CBDT/CBLC PNG, grayscale, BGRA, and composite bitmaps

### Limits

Alhena does not provide TrueType hinting, shaping, GSUB/GPOS, kerning, system font discovery, COLR v1 paint graphs, avar v2, JPEG/TIFF decoding, or MVAR global metric variation. Use `embedded_bitmap` to retrieve unsupported sbix image formats for external decoding.

Unknown formats raise `Alhena::UnsupportedFont`; malformed bounds and structures raise `Alhena::InvalidFont`. Bitmap allocations are limited to 16,777,216 samples.

## Performance

Measurements below are medians of five batches on Ruby 4.0.0 with YJIT on arm64-darwin24. Run `ruby --yjit bench/bench.rb` to reproduce them.

| Operation | Measured | Budget |
|---|---:|---:|
| Open Noto Sans (569,208 bytes) | 64.73 µs | 30,000 µs |
| A at 14px, uncached | 40.11 µs | 500 µs |
| A at 14px, cache hit | 0.48 µs | 5 µs |
| ASCII 95 glyph prewarm | 4.79 ms | 60 ms |
| 鬱 at 48px, uncached | 0.47 ms | 3 ms |

Cache glyphs in interactive applications so each glyph is normally rasterized once per size and position. These measurements are local evidence, not universal guarantees.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rake test:oracle
bundle exec rake test:fuzz
bundle exec rake bench:assert
```

Oracle tests compare Alhena with FreeType, ttfunk, and committed PNG references. FreeType is development-only; install `libfreetype6` on Linux or `freetype` with Homebrew on macOS, or set `FREETYPE_LIBRARY`. Optional oracle dependencies are skipped when unavailable.

Render the bundled examples with:

```sh
bundle exec ruby examples/render.rb test/fonts/NotoSans-Regular.ttf "Hello, Ruby!" 48 text.png
bundle exec ruby examples/color.rb test/fonts/NotoColorEmoji.ttf "😀" 64 color.png
```

See the [changelog](CHANGELOG.md) for release history. Bug reports and pull requests are welcome on [GitHub](https://github.com/noxdea/alhena).

## License

Alhena is available under the [MIT License](LICENSE.txt). Test font licenses and upstream sources are recorded in [test/fonts/README.md](test/fonts/README.md).
