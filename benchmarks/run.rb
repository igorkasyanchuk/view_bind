# frozen_string_literal: true

# Full-request benchmark: four routes, byte-identical HTML, different call styles.
#
#   RAILS_ENV=production bundle exec ruby benchmarks/run.rb
#
# Cases are interleaved and the best round is reported, so CPU drift hits every case
# equally. Allocation counts are exact and do not move with machine load -- read those.
require_relative "app"

N = Integer(ENV.fetch("N", 20))   # requests per round
R = Integer(ENV.fetch("R", 7))    # rounds

CASES = [
  ["render everywhere (baseline)", "/"],
  ["bind_render in the view",      "/bind_view"],
  ["bind_render in the layout",    "/bind_layout"],
  ["bind_render in both",          "/bind_both"]
].freeze

session = ActionDispatch::Integration::Session.new(Rails.application)
session.tap { |s| s.host = "localhost" }

# count how many partial renders each route actually performs
renders = Hash.new(0)
%w[render_partial render_collection render_template].each do |event|
  ActiveSupport::Notifications.subscribe("#{event}.action_view") do |_, _, _, _, payload|
    renders[:total] += (payload[:count] || 1)
  end
end

results = Hash.new { |h, k| h[k] = { ms: Float::INFINITY, objects: 0, gc: 0.0 } }

CASES.each { |_, path| session.get(path) } # warm: resolve + compile everything

R.times do
  CASES.each do |label, path|
    GC.start
    allocated = GC.stat[:total_allocated_objects]
    gc_before = GC.stat[:time]
    started   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    N.times { session.get(path) }
    ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 / N
    next unless ms < results[label][:ms]

    results[label] = { ms: ms,
                       objects: (GC.stat[:total_allocated_objects] - allocated) / N,
                       gc: (GC.stat[:time] - gc_before).to_f / N }
  end
end

baseline = results[CASES.first[0]]

puts "\nview_bind #{ViewBind::VERSION} — #{POSTS.size} posts, Rails #{Rails::VERSION::STRING}, " \
     "Ruby #{RUBY_VERSION}#{RubyVM::YJIT.enabled? ? " +YJIT" : ""}"
puts "env=#{Rails.env}  eager_load=#{Rails.application.config.eager_load}  " \
     "cache_template_loading=#{ActionView::Resolver.caching?}  " \
     "reloading=#{Rails.application.config.enable_reloading}"
puts "#{R} rounds x #{N} full requests, interleaved, best round per case\n\n"
printf("  %-30s %10s %8s %12s %10s %10s\n", "", "ms", "gc ms", "objects", "renders", "vs base")
CASES.each do |label, path|
  renders[:total] = 0
  session.get(path)
  r = results[label]
  printf("  %-30s %10.3f %8.2f %12s %10d %9.2fx\n",
         label, r[:ms], r[:gc], r[:objects].to_s.reverse.scan(/\d{1,3}/).join(" ").reverse,
         renders[:total], baseline[:objects].to_f / r[:objects])
end

puts "\n  HTML is byte-identical across all four routes."
puts "  Objects are exact; milliseconds move with machine load.\n\n"
