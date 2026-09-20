# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/test_*.rb"
end
namespace :test do
  Rake::TestTask.new(:oracle) do |task|
    task.libs << "test"
    task.pattern = "test/oracle/test_*.rb"
  end
  task(:fuzz) { ruby "test/fuzz.rb" }
end
task(:bench) do
  ruby "--yjit", "bench/bench.rb"
  ruby "--yjit", "bench/downsample.rb"
end
namespace :bench do
  task(:assert) do
    ruby "--yjit", "bench/bench.rb", "--assert"
    ruby "--yjit", "bench/downsample.rb", "--assert"
  end
end
task default: :test

desc "Regenerate deterministic demo media"
task :demo do
  Dir["demo/*.rb"].sort.each { |path| ruby "-Ilib", path }
end
