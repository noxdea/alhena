# frozen_string_literal: true

require_relative "alhena/version"
require_relative "alhena/data_compat"

module Alhena
  class Error < StandardError; end
  class InvalidFont < Error; end
  class UnsupportedFont < Error; end
end

require_relative "alhena/bitmap"
require_relative "alhena/outline"
require_relative "alhena/binary"
require_relative "alhena/rasterizer"
require_relative "alhena/cff"
require_relative "alhena/font"
require_relative "alhena/variation"
require_relative "alhena/png"
require_relative "alhena/color"
require_relative "alhena/cache"
