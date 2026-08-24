# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Run the benchmark suite against the dummy app"
task :bench do
  sh({ "RAILS_ENV" => "production" }, "ruby benchmarks/run.rb")
end

desc "Serve the dummy app at http://localhost:9292 (routes: / /bind_view /bind_layout /bind_both)"
task :dummy do
  sh({ "RAILS_ENV" => "development" }, "rackup -p 9292")
end

task default: :test
