# frozen_string_literal: true

module Alhena
  # A path in font units, or arbitrary coordinates for Rasterizer#fill.
  class Outline
    attr_reader :commands, :coordinates

    def initialize
      @commands = []
      @coordinates = []
    end

    def move_to(x, y) = add(:move_to, x, y)
    def line_to(x, y) = add(:line_to, x, y)
    def quad_to(cx, cy, x, y) = add(:quad_to, cx, cy, x, y)
    def cubic_to(c1x, c1y, c2x, c2y, x, y) = add(:cubic_to, c1x, c1y, c2x, c2y, x, y)
    def close = add(:close)
    def empty? = @coordinates.empty?

    def each
      return enum_for(__method__) unless block_given?
      offset = 0
      @commands.each do |command|
        length = {move_to: 2, line_to: 2, quad_to: 4, cubic_to: 6, close: 0}.fetch(command)
        yield command, *@coordinates.slice(offset, length)
        offset += length
      end
      self
    end

    # Matrix is [xx, yx, xy, yy, dx, dy], as used by SVG and Canvas.
    def transform(matrix)
      raise ArgumentError, "matrix must have six finite numbers" unless matrix.length == 6 && matrix.all? { |n| n.is_a?(Numeric) && n.finite? }
      a, b, c, d, e, f = matrix
      result = self.class.new
      result.commands.concat(@commands)
      @coordinates.each_slice(2) { |x, y| result.coordinates.push(a * x + c * y + e, b * x + d * y + f) }
      result
    end

    def append(other)
      @commands.concat(other.commands)
      @coordinates.concat(other.coordinates)
      self
    end

    def bounds
      return [0, 0, 0, 0] if empty?
      xs, ys = @coordinates.each_slice(2).to_a.transpose
      [xs.min, ys.min, xs.max, ys.max]
    end

    # Reduce cubics to quadratic segments with a bounded coordinate error.
    def to_quadratic(tolerance: 0.25)
      raise ArgumentError, "tolerance must be positive" unless tolerance.is_a?(Numeric) && tolerance.finite? && tolerance > 0
      result = self.class.new
      x = y = sx = sy = 0.0
      each do |command, *args|
        if command == :cubic_to
          reduce_cubic(result, [x, y, *args], tolerance, 0)
        else
          result.public_send(command, *args)
        end
        case command
        when :move_to
          sx, sy = args
          x, y = args
        when :close then x, y = sx, sy
        else x, y = args[-2, 2]
        end
      end
      result
    end

    private

    def reduce_cubic(result, points, tolerance, depth)
      x0, y0, ax, ay, bx, by, x1, y1 = points
      error = Math.hypot(-x0 + 3 * ax - 3 * bx + x1, -y0 + 3 * ay - 3 * by + y1) / (12 * Math.sqrt(3))
      if error <= tolerance || depth >= 16
        result.quad_to((3 * ax + 3 * bx - x0 - x1) / 4.0, (3 * ay + 3 * by - y0 - y1) / 4.0, x1, y1)
      else
        p0, p1, p2, p3 = points.each_slice(2).to_a
        a, b, c = [p0, p1, p2, p3].each_cons(2).map { |u, v| [(u[0] + v[0]) / 2, (u[1] + v[1]) / 2] }
        d, e = [a, b, c].each_cons(2).map { |u, v| [(u[0] + v[0]) / 2, (u[1] + v[1]) / 2] }
        middle = [(d[0] + e[0]) / 2, (d[1] + e[1]) / 2]
        reduce_cubic(result, [*p0, *a, *d, *middle], tolerance, depth + 1)
        reduce_cubic(result, [*middle, *e, *c, *p3], tolerance, depth + 1)
      end
    end

    def add(command, *values)
      raise ArgumentError, "coordinates must be finite" unless values.all? { |n| n.is_a?(Numeric) && n.finite? }
      raise ArgumentError, "path must start with move_to" if @commands.empty? && command != :move_to
      @commands << command
      @coordinates.concat(values.map(&:to_f))
      self
    end
  end
end
