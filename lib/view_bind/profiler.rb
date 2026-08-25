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

    class << self
      # count: how many renders this call represents (a collection counts as its size).
      # memo_hits: how many of them were served from bind_render_memo without rendering.
      def record(path, elapsed, count: 1, memo_hits: 0)
        row = store[path]
        row[0] += count
        row[1] += elapsed
        row[2] += memo_hits
      end

      def store
        Thread.current[KEY] ||= Hash.new { |hash, key| hash[key] = [0, 0.0, 0] }
      end

      # Called at the start and the end of an action. Renders outside a controller action --
      # a mailer, a job, ActionCable -- would otherwise be counted against whichever request
      # next runs on this thread.
      def reset
        Thread.current[KEY] = nil
      end

      # A pure read: returns nil when nothing was recorded, so the caller logs nothing and
      # can ask twice without the second answer being empty.
      def summary(limit: 10)
        rows = Thread.current[KEY]
        return nil if rows.nil? || rows.empty?

        calls = rows.sum { |_, (count, _, _)| count }
        total = rows.sum { |_, (_, seconds, _)| seconds }
        lines = ["ViewBind: #{calls} calls, #{format('%.2f', total * 1000)}ms"]
        rows.sort_by { |_, (_, seconds, _)| -seconds }.first(limit).each do |path, (count, seconds, hits)|
          suffix = hits.positive? ? "  (#{hits} memo)" : ""
          lines << format("  %-34s x%-6d %6.2fms%s", path, count, seconds * 1000, suffix)
        end
        lines << "  … and #{rows.size - limit} more partials" if rows.size > limit
        lines.join("\n")
      end
    end
  end
end
