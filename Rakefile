# frozen_string_literal: true

require "rake/testtask"

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
task(:bench) { ruby "--yjit", "bench/bench.rb" }
namespace :bench do
  task(:assert) { ruby "--yjit", "bench/bench.rb", "--assert" }
end
task default: :test
