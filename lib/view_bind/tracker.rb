# frozen_string_literal: true

module ViewBind
  # Teaches ActionView::Digestor about bind_render, so a fragment cache key still changes
  # when a bound partial changes. Without this, editing a partial that is only reached
  # through bind_render leaves every parent's `cache` key untouched and serves stale HTML.
  #
  # Only handlers this is registered for are tracked. ERB is registered automatically; for
  # another template engine, call ViewBind::Tracker.register_for(:haml) in an initializer.
  class Tracker
    DIRECTIVE = /\bbind_(?:render|capture)(?:_each)?\s+["']([^"']+)["']/

    # handler => the tracker that was registered before us, so we extend rather than replace
    @wrapped = {}

    class << self
      attr_reader :wrapped

      def supports_view_paths? = true

      # Registers for `extension`, keeping whatever tracker was already registered for that
      # handler so its dependencies are still reported. Another gem's custom ERB tracker
      # must not disappear just because this gem loaded after it.
      def register_for(extension)
        handler = ActionView::Template.handler_for_extension(extension)
        @wrapped[handler] ||= existing_tracker_for(handler)
        ActionView::DependencyTracker.register_tracker(extension, self)
      end

      def call(name, template, view_paths = nil)
        inherited = wrapped[template.handler]
        base = inherited || default_tracker
        base.call(name, template, view_paths) | template.source.scan(DIRECTIVE).flatten
      end

      # Rails' default for ERB. Named `:ruby` (AST) from Rails 8; earlier versions only ship
      # the regex tracker, and ActionView.render_tracker does not exist there at all.
      def default_tracker
        if ActionView.respond_to?(:render_tracker) && ActionView.render_tracker == :ruby
          ActionView::DependencyTracker::RubyTracker
        else
          ActionView::DependencyTracker::ERBTracker
        end
      end

      private

      # DependencyTracker exposes no reader for a handler's tracker, so this reaches for the
      # registry directly and falls back to the framework default if that ever changes.
      def existing_tracker_for(handler)
        registry = ActionView::DependencyTracker.instance_variable_get(:@trackers)
        found = registry.respond_to?(:[]) ? registry[handler] : nil
        found unless found == self
      rescue StandardError
        nil
      end
    end
  end
end
