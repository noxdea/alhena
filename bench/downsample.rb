# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "alhena"

outline = Alhena::Outline.new.move_to(0, 0).line_to(3, 0).line_to(3, 2).line_to(0, 2).close
rasterizer = Alhena::Rasterizer.new(width: 1, height: 1)
3.times do
  rasterizer.fill_downsampled([outline], scale: 0.5, width: 2, height: 1)
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
10_000.times do
  rasterizer.fill_downsampled([outline], scale: 0.5, width: 2, height: 1)
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts "10k downsampled rows: %.2f ms (budget 200.00 ms)" % (elapsed * 1000)
assert_budget = ARGV.include?("--assert") || ENV["BUDGET"] == "1"
abort "downsampled row generation exceeds budget" if assert_budget && elapsed > 0.2
