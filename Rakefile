# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Run the test suite with line and branch coverage (coverage/index.html)"
task :coverage do
  ENV["COVERAGE"] = "1"
  # reenable, so that `rake test coverage` runs the suite again under SimpleCov rather than
  # silently doing nothing because :test is already marked invoked.
  Rake::Task[:test].reenable
  Rake::Task[:test].invoke
end

# `rake test` boots the suite's own miniature application, so nothing in it ever loads
# benchmarks/app.rb. This does, in a subprocess per configuration, because the log settings
# are read once while the app boots. A blank LOG_LEVEL once assigned "" and failed to boot and
# no test could have caught it; the quiet default matters just as much, since `rake bench`
# would otherwise time a request log line as part of the render.
desc "Boot the dummy app and check its logging configuration"
task :smoke do
  # Non-interpolating heredoc: every #{} below belongs to the child process, not to this file.
  # The expectations travel in the environment so the script itself never has to be generated.
  script = <<~'RUBY'
    require_relative "benchmarks/app"
    abort "no rows: the dummy app did not seed" unless Post.count.positive?

    actual = Rails.application.config.log_level.to_s
    want = ENV.fetch("EXPECT_LEVEL")
    abort "expected log_level #{want.inspect}, got #{actual.inspect}" unless actual == want

    # Logger.new(IO::NULL) opens a File on /dev/null, so the device is never the IO::NULL
    # string; what matters is only whether it is the terminal this process writes to.
    device = Rails.application.config.logger.instance_variable_get(:@logdev)&.dev
    quiet = !device.equal?($stdout)
    want_quiet = ENV.fetch("EXPECT_QUIET") == "1"
    abort "expected logging to #{want_quiet ? 'IO::NULL' : '$stdout'}, got #{device.inspect}" unless quiet == want_quiet
  RUBY

  # nil is LOG_LEVEL unset, "" is a variable cleared in a shell profile. Both mean quiet, which
  # is what `rake bench` depends on: a request log line per request would be timed as part of
  # the render. Each runs in its own process because the settings are read once, at boot.
  [[nil, "fatal", true], ["", "fatal", true], ["info", "info", false]].each do |value, level, quiet|
    env = { "RAILS_ENV" => "production", "EXPECT_LEVEL" => level, "EXPECT_QUIET" => (quiet ? "1" : "0") }
    env["LOG_LEVEL"] = value unless value.nil?
    sh(env, RbConfig.ruby, "-e", script) do |ok, _|
      abort "smoke failed for LOG_LEVEL=#{value.inspect}" unless ok
    end
  end
  puts "smoke: the dummy app boots and logs correctly for three LOG_LEVEL settings"
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
