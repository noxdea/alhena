# frozen_string_literal: true

module Alhena
  # Analytic signed-area scan conversion; no supersampling for grayscale.
  class Rasterizer
    MAX_PIXELS = 16_777_216

    def initialize(width:, height:, tolerance: 0.25)
      unless [width, height].all? { |n| n.is_a?(Integer) && n >= 0 && n <= MAX_PIXELS } && width * height <= MAX_PIXELS
        raise ArgumentError, "invalid or excessively large raster dimensions"
      end
      raise ArgumentError, "tolerance must be positive" unless tolerance.is_a?(Numeric) && tolerance.finite? && tolerance > 0
      @width, @height, @tolerance = width, height, tolerance.to_f
    end

    # Coordinates increase right and down. Open subpaths are implicitly closed.
    # darkening is a coverage-space gain (0..1); gamma is a positive exponent.
    def fill(outline, transform: nil, left: 0, top: 0, gamma: 1.0, darkening: 0.0, lcd: nil)
      raise ArgumentError, "gamma must be positive" unless gamma.is_a?(Numeric) && gamma.finite? && gamma > 0
      raise ArgumentError, "darkening must be between 0 and 1" unless darkening.is_a?(Numeric) && darkening.finite? && (0..1).cover?(darkening)
      raise ArgumentError, "LCD order must be :rgb or :bgr" unless [nil, :rgb, :bgr].include?(lcd)
      if @width.zero? || @height.zero?
        return Bitmap.new(width: @width, height: @height, left: left, top: top, coverage: "", channels: lcd ? 3 : 1)
      end
      outline = outline.transform(transform) if transform
      return lcd_bitmap(outline, left: left, top: top, gamma: gamma, darkening: darkening, order: lcd) if lcd
      @area = Array.new((@width + 1) * @height, 0.0)
      draw_outline(outline)
      Bitmap.new(width: @width, height: @height, left: left, top: top, coverage: grayscale_coverage(gamma, darkening))
    ensure
      @area = nil
    end

    private

    def lcd_bitmap(outline, left:, top:, gamma:, darkening:, order:)
      high = self.class.new(width: @width * 3 + 4, height: @height, tolerance: @tolerance)
      coverage = high.fill(outline, transform: [3, 0, 0, 1, 2, 0]).coverage
      output = String.new(capacity: @width * @height * 3, encoding: Encoding::BINARY)
      @height.times do |y|
        @width.times do |x|
          values = 3.times.map do |channel|
            at = y * (@width * 3 + 4) + x * 3 + channel
            value = (coverage.getbyte(at) + 2 * coverage.getbyte(at + 1) + 3 * coverage.getbyte(at + 2) +
                     2 * coverage.getbyte(at + 3) + coverage.getbyte(at + 4)) / (9.0 * 255)
            encode_coverage(value, gamma, darkening)
          end
          values.reverse! if order == :bgr
          values.each { |value| output << value }
        end
      end
      Bitmap.new(width: @width, height: @height, left: left, top: top, coverage: output, channels: 3)
    end

    def draw_outline(outline)
      x = y = sx = sy = 0.0
      opened = false
      outline.each do |command, *args|
        case command
        when :move_to
          draw_line(x, y, sx, sy) if opened
          x, y = args
          sx, sy = x, y
          opened = true
        when :line_to
          draw_line(x, y, *args)
          x, y = args
        when :quad_to
          flatten_quad(x, y, *args)
          x, y = args[-2, 2]
        when :cubic_to
          flatten_cubic(x, y, *args)
          x, y = args[-2, 2]
        when :close
          draw_line(x, y, sx, sy) if opened
          x, y, opened = sx, sy, false
        end
      end
      draw_line(x, y, sx, sy) if opened
    end

    def grayscale_coverage(gamma, darkening)
      output = String.new(capacity: @width * @height, encoding: Encoding::BINARY)
      @height.times do |row|
        acc = 0.0
        @width.times do |col|
          acc += @area[row * (@width + 1) + col]
          output << encode_coverage([acc.abs, 1.0].min, gamma, darkening)
        end
      end
      output
    end

    def encode_coverage(value, gamma, darkening)
      value = [value * (1.0 + darkening), 1.0].min
      ((gamma == 1.0 ? value : value**(1.0 / gamma)) * 255).round
    end

    def flatten_quad(x0, y0, cx, cy, x1, y1)
      deviation = [(x0 - 2 * cx + x1).abs, (y0 - 2 * cy + y1).abs].max
      needed = [Math.sqrt(deviation / @tolerance).ceil, 1].max
      count = [1 << (needed - 1).bit_length, 4096].min
      px, py = x0, y0
      1.upto(count) do |i|
        t = i.to_f / count
        s = 1.0 - t
        x = s * s * x0 + 2 * s * t * cx + t * t * x1
        y = s * s * y0 + 2 * s * t * cy + t * t * y1
        draw_line(px, py, x, y)
        px, py = x, y
      end
    end

    def flatten_cubic(x0, y0, c1x, c1y, c2x, c2y, x1, y1, depth = 0)
      deviation = [(2 * x1 - 3 * c2x + x0).abs, (2 * y1 - 3 * c2y + y0).abs,
                   (x1 - 3 * c1x + 2 * x0).abs, (y1 - 3 * c1y + 2 * y0).abs].max
      if deviation <= @tolerance * 2 || depth >= 16
        draw_line(x0, y0, x1, y1)
      else
        ax, ay = (x0 + c1x) / 2.0, (y0 + c1y) / 2.0
        bx, by = (c1x + c2x) / 2.0, (c1y + c2y) / 2.0
        cx, cy = (c2x + x1) / 2.0, (c2y + y1) / 2.0
        dx, dy = (ax + bx) / 2.0, (ay + by) / 2.0
        ex, ey = (bx + cx) / 2.0, (by + cy) / 2.0
        mx, my = (dx + ex) / 2.0, (dy + ey) / 2.0
        flatten_cubic(x0, y0, ax, ay, dx, dy, mx, my, depth + 1)
        flatten_cubic(mx, my, ex, ey, cx, cy, x1, y1, depth + 1)
      end
    end

    # Integral of clamp(x, 0, 1), used to integrate an edge's cell coverage.
    def coverage_integral(x)
      x <= 0 ? 0.0 : x >= 1 ? x - 0.5 : x * x * 0.5
    end

    def draw_line(x0, y0, x1, y1)
      return if y0 == y1 || @width.zero? || @height.zero?
      sign = 1.0
      if y0 > y1
        x0, y0, x1, y1 = x1, y1, x0, y0
        sign = -1.0
      end
      first, last = [y0.floor, 0].max, [y1.ceil, @height].min
      slope = (x1 - x0) / (y1 - y0)
      first.upto(last - 1) do |row|
        ya, yb = [y0, row].max, [y1, row + 1].min
        xa, xb = x0 + (ya - y0) * slope, x0 + (yb - y0) * slope
        xa, xb = xb, xa if xa > xb
        height = (yb - ya) * sign
        at = row * (@width + 1)
        if xb <= 0
          @area[at] += height
          next
        end
        next if xa >= @width
        start, finish = [xa.floor, 0].max, [xb.floor, @width - 1].min
        previous = 0.0
        start.upto(finish) do |col|
          fraction = if xb - xa < 1e-12
            [[col + 1 - xa, 0].max, 1].min
          else
            (coverage_integral(col + 1 - xa) - coverage_integral(col + 1 - xb)) / (xb - xa)
          end
          value = height * fraction
          @area[at + col] += value - previous
          previous = value
        end
        @area[at + finish + 1] += height - previous
      end
    end
  end
end
