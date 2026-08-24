# frozen_string_literal: true

module ViewBind
  # Teaches ActionView::Digestor about bind_render, so a fragment cache key still changes
  # when a bound partial changes. Without this, editing a partial that is only reached
  # through bind_render leaves every parent's `cache` key untouched and serves stale HTML.
  class Tracker
    DIRECTIVE = /\bbind_render(?:_each)?\s+["']([^"']+)["']/

    class << self
      def supports_view_paths? = true

      # Delegate to whichever tracker the app is configured for. Rails 7.1+ can use the
      # AST-based RubyTracker; hardcoding ERBTracker here would silently downgrade
      # dependency detection for every ERB template in the application.
      def base
        if ActionView.respond_to?(:render_tracker) && ActionView.render_tracker == :ruby
          ActionView::DependencyTracker::RubyTracker
        else
          ActionView::DependencyTracker::ERBTracker
        end
      end

      def call(name, template, view_paths = nil)
        base.call(name, template, view_paths) | template.source.scan(DIRECTIVE).flatten
      end
    end
  end
end
