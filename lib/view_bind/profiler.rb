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
      def record(path, elapsed, count = 1)
        row = store[path]
        row[0] += count
        row[1] += elapsed
      end

      def store
        Thread.current[KEY] ||= Hash.new { |hash, key| hash[key] = [0, 0.0] }
      end

      def flush
        rows = Thread.current[KEY]
        Thread.current[KEY] = nil
        rows
      end

      # Returns nil when nothing was recorded, so the caller logs nothing.
      def summary(rows = flush, limit: 10)
        return nil if rows.nil? || rows.empty?

        calls = rows.sum { |_, (count, _)| count }
        total = rows.sum { |_, (_, seconds)| seconds }
        lines = ["ViewBind: #{calls} calls, #{format('%.2f', total * 1000)}ms"]
        rows.sort_by { |_, (_, seconds)| -seconds }.first(limit).each do |path, (count, seconds)|
          lines << format("  %-34s x%-6d %6.2fms", path, count, seconds * 1000)
        end
        lines << "  … and #{rows.size - limit} more partials" if rows.size > limit
        lines.join("\n")
      end
    end
  end
end
