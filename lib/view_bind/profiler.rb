# frozen_string_literal: true

module ViewBind
  # Bound partials emit no render_partial.action_view events -- that is part of what makes
  # them cheap -- so Rails' per-partial "Rendered ..." log lines disappear for them. This is
  # the replacement: one line per request instead of one per render.
  #
  #   # config/environments/development.rb
  #   ViewBind.profile = true
  #
  #   ViewBind: 2662 calls, 4.12ms
  #     posts/card_bound   x200   1.83ms
  #     shared/tag         x600   0.91ms
  #
  # Off by default, and when off the only cost is one boolean test per call.
  module Profiler
    KEY = :view_bind_profile
    DEPTH = :view_bind_profile_depth

    class << self
      # Times a bound render. Nesting is tracked so the header can total only the outermost
      # calls: a parent's duration already contains its children's, and adding every row
      # would count the children twice.
      def measure(path, count: 1, memo_hits: 0)
        depth = Thread.current[DEPTH] || 0
        Thread.current[DEPTH] = depth + 1
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        Thread.current[DEPTH] = depth
        record(path, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
               count: count, memo_hits: memo_hits, top_level: depth.zero?)
      end

      # Same as #measure, for bind_render_memo: whether the call was a hit is only known
      # once the block has run, so the block reports it by returning true (hit), false (miss)
      # or :delegated when the call was handed to bind_render, which measures itself.
      def measure_memo(path)
        depth = Thread.current[DEPTH] || 0
        Thread.current[DEPTH] = depth + 1
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
      ensure
        Thread.current[DEPTH] = depth
        unless result == :delegated
          record(path, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                 memo_hits: result ? 1 : 0, top_level: depth.zero?)
        end
      end

      # count: how many renders this call represents (a collection counts as its size).
      # memo_hits: how many of them were served from bind_render_memo without rendering.
      # top_level: whether this call was not nested inside another bound render.
      def record(path, elapsed, count: 1, memo_hits: 0, top_level: true)
        row = store[path]
        row[0] += count
        row[1] += elapsed
        row[2] += memo_hits
        row[3] += elapsed if top_level
      end

      def store
        Thread.current[KEY] ||= Hash.new { |hash, key| hash[key] = [0, 0.0, 0, 0.0] }
      end

      # Called at the start and the end of an action. Renders outside a controller action --
      # a mailer, a job, ActionCable -- would otherwise be counted against whichever request
      # next runs on this thread.
      def reset
        Thread.current[KEY] = nil
        Thread.current[DEPTH] = nil
      end

      # A pure read: returns nil when nothing was recorded, so the caller logs nothing and
      # can ask twice without the second answer being empty.
      def summary(limit: 10)
        rows = Thread.current[KEY]
        return nil if rows.nil? || rows.empty?

        calls = rows.sum { |_, row| row[0] }
        # Only outermost calls, so a parent and its children are not both counted.
        total = rows.sum { |_, row| row[3] }
        lines = ["ViewBind: #{calls} calls, #{format('%.2f', total * 1000)}ms in bound partials"]
        rows.sort_by { |_, row| -row[1] }.first(limit).each do |path, (count, seconds, hits, _)|
          suffix = hits.positive? ? "  (#{hits} memo)" : ""
          lines << format("  %-34s x%-6d %6.2fms%s", path, count, seconds * 1000, suffix)
        end
        omitted = rows.size - limit
        lines << "  … and #{omitted} more #{'partial'.pluralize(omitted)}" if omitted.positive?
        lines.join("\n")
      end
    end
  end
end
