# frozen_string_literal: true

# Serial, full-request benchmark. See README for options and interpretation.
ENV["RAILS_ENV"] ||= "production"

N = Integer(ENV.fetch("N", 20))
R = Integer(ENV.fetch("R", 9))
WARMUP = Integer(ENV.fetch("WARMUP", 15))
PER = Integer(ENV.fetch("PER", 200))
SEED = Integer(ENV.fetch("SEED", 20260905))
abort "N, R and WARMUP must be positive; PER must be 1..500" unless
  [N, R, WARMUP].all?(&:positive?) && (1..500).cover?(PER)

require_relative "app"
require "json"
require "fileutils"

CASES = [
  ["render everywhere (baseline)", "/"],
  ["bind_render in the view", "/bind_view"],
  ["bind_render in the layout", "/bind_layout"],
  ["bind_render in both", "/bind_both"],
  ["+ memoised subtree", "/bind_memo"]
].freeze

def median(values)
  sorted = values.sort
  middle = sorted.size / 2
  sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

session = ActionDispatch::Integration::Session.new(Rails.application)
session.host = "localhost"
request = lambda do |path|
  session.get("#{path}?per=#{PER}")
  abort "HTTP #{session.response.status} for #{path}" unless session.response.status == 200
end
normalise = ->(body) { body.sub(/rendered \d\d:\d\d:\d\d\.\d+/, "TIME") }

ActiveRecord::Base.logger = nil
# The dummy app turns profiling on in development so that browsing it shows the summary. That
# would time every bind_render through Profiler.measure while leaving the baseline's `render`
# untouched, so the documented development run would understate the gem it is measuring.
ViewBind.profile = false
counts = { queries: 0, observed_renders: 0 }
attach_counters = lambda do
  ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
    counts[:queries] += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
  end
  %w[render_partial render_collection render_template].each do |event|
    ActiveSupport::Notifications.subscribe("#{event}.action_view") do |_, _, _, _, payload|
      counts[:observed_renders] += payload[:count] || 1
    end
  end
end
instrumented = ENV["APM"] == "1"
attach_counters.call if instrumented

reference = nil
CASES.each do |label, path|
  request.call(path)
  body = normalise.call(session.response.body)
  abort "Wrong page for #{label}" unless body.include?("The latest stories")
  reference ||= body
  abort "HTML differs for #{label}" unless body == reference
end

WARMUP.times { CASES.each { |_, path| request.call(path) } }
samples = Hash.new { |hash, key| hash[key] = [] }
random = Random.new(SEED)
R.times do
  CASES.shuffle(random: random).each do |label, path|
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    gc_before = GC.stat(:time)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    N.times { request.call(path) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    objects = GC.stat(:total_allocated_objects) - allocated
    gc = GC.stat(:time) - gc_before
    samples[label] << { ms: elapsed * 1000 / N, objects: objects.to_f / N, gc_ms: gc.to_f / N }
    abort "HTML changed for #{label}" unless normalise.call(session.response.body) == reference
  end
end

attach_counters.call unless instrumented
results = CASES.to_h do |label, path|
  counts.transform_values! { 0 }
  request.call(path)
  abort "HTML changed for #{label}" unless normalise.call(session.response.body) == reference
  rows = samples.fetch(label)
  [label, {
    path: path,
    median_ms: median(rows.map { |row| row[:ms] }),
    min_ms: rows.map { |row| row[:ms] }.min,
    max_ms: rows.map { |row| row[:ms] }.max,
    median_objects: median(rows.map { |row| row[:objects] }),
    median_gc_ms: median(rows.map { |row| row[:gc_ms] }),
    **counts, samples: rows
  }]
end
abort "Query counts differ between routes" unless results.values.map { |row| row[:queries] }.uniq.one?

baseline = results.fetch(CASES.first.first)
yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
metadata = {
  gem_version: ViewBind::VERSION, ruby: RUBY_DESCRIPTION, rails: Rails.version,
  database: ActiveRecord::Base.connection.adapter_name, environment: Rails.env,
  yjit: !!yjit, eager_load: Rails.application.config.eager_load,
  cache_template_loading: ActionView::Resolver.caching?,
  reloading: Rails.application.config.enable_reloading,
  posts_per_page: PER, posts: Post.count, comments: Comment.count,
  rounds: R, requests_per_round: N, warmups_per_case: WARMUP, seed: SEED,
  instrumentation: instrumented, verified_html_bytes: reference.bytesize
}

puts "\nview_bind #{ViewBind::VERSION} — Rails #{Rails.version}, Ruby #{RUBY_VERSION}#{yjit ? ' +YJIT' : ''}"
puts "#{metadata[:database]}, #{Rails.env}, #{PER} posts per page"
puts "#{R} rounds × #{N} requests; #{WARMUP} warmups per case; randomized order (seed #{SEED})"
puts "Median batch averages; min–max shows batch variation, not request percentiles."
puts "Inspection counters #{instrumented ? 'attached during timing (synthetic APM=1)' : 'excluded from timing'}.\n\n"
printf("  %-30s %9s %19s %11s %9s %8s %8s\n",
       "", "median ms", "min–max ms", "objects", "observed", "queries", "time x")
results.each do |label, row|
  printf("  %-30s %9.3f %9.3f–%9.3f %11.1f %9d %8d %7.2fx\n",
         label, row[:median_ms], row[:min_ms], row[:max_ms], row[:median_objects],
         row[:observed_renders], row[:queries], baseline[:median_ms] / row[:median_ms])
end
puts "\n#{metadata[:posts]} posts / #{metadata[:comments]} comments; #{baseline[:queries]} SQL queries per request."
puts "Equivalent HTML across all five routes after timestamp normalization (#{reference.bytesize} bytes)."
puts "'observed' counts template instances reported by Rails notifications, including collection payloads."
puts "Bound templates still execute even when they emit no render notifications."
puts "Allocations are per-request averages. Browser/network time and concurrent load are not measured."

if ENV["OUTPUT"]
  FileUtils.mkdir_p(File.dirname(ENV.fetch("OUTPUT")))
  File.write(ENV.fetch("OUTPUT"), JSON.pretty_generate(metadata: metadata, results: results) + "\n")
  puts "Raw results: #{ENV.fetch('OUTPUT')}"
end
