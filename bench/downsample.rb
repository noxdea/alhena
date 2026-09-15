# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "alhena"

outlines = [[0, 12], [16, 18], [38, 9], [51, 27]].map do |x, width|
  Alhena::Outline.new.move_to(x, 0).line_to(x + width, 0).line_to(x + width, 2).line_to(x, 2).close
end
rasterizer = Alhena::Rasterizer.new(width: 1, height: 1)
3.times do
  rasterizer.fill_downsampled(outlines, scale: 1, width: 80, height: 1)
end

times = 5.times.map do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  10_000.times do
    rasterizer.fill_downsampled(outlines, scale: 1, width: 80, height: 1)
  end
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end
elapsed = times.sort[2]
puts "10k downsampled rows: %.2f ms (budget 250.00 ms)" % (elapsed * 1000)
assert_budget = ARGV.include?("--assert") || ENV["BUDGET"] == "1"
abort "downsampled row generation exceeds budget" if assert_budget && elapsed > 0.25
