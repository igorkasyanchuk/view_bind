# frozen_string_literal: true

module ViewBind
  # Teaches ActionView::Digestor about bind_render, so a fragment cache key still changes
  # when a bound partial changes. Without this, editing a partial that is only reached
  # through bind_render leaves every parent's `cache` key untouched and serves stale HTML.
  #
  # Only handlers this is registered for are tracked. ERB is registered automatically; for
  # another template engine, call ViewBind::Tracker.register_for(:haml) in an initializer.
  class Tracker
    # Every public helper form: bind_render, bind_capture, bind_render_each,
    # bind_render_memo, with or without parentheses. Missing one leaves a parent's fragment
    # digest unchanged when the partial it names is edited.
    #
    # The path may only start a new line once a parenthesis has been opened. Allowing a bare
    # line break would make a plain string literal on the line after an argument-less call
    # look like that call's path.
    # `#` cannot appear in a virtual path, so excluding it drops interpolated names such as
    # "posts/#{kind}_card" rather than reporting a dependency that resolves to nothing. Rails'
    # own tracker turns those into a "posts/*_card" wildcard; matching that is a larger job
    # than this regex, and reporting nothing is the same answer it gives for a dynamic path.
    DIRECTIVE = /\bbind_(?:render|capture)(?:_each|_memo)?(?:[ \t]*\(\s*|[ \t]+)["']([^"'#]+)["']/

    # handler => the tracker that was registered before us, so we extend rather than replace
    @wrapped = {}

    class << self
      attr_reader :wrapped

      def supports_view_paths? = true

      # Registers for `extension`, keeping whatever tracker was already registered for that
      # handler so its dependencies are still reported. Another gem's custom ERB tracker
      # must not disappear just because this gem loaded after it.
      def register_for(extension)
        require "action_view/dependency_tracker"
        handler = ActionView::Template.handler_for_extension(extension)
        @wrapped[handler] ||= existing_tracker_for(handler)
        ActionView::DependencyTracker.register_tracker(extension, self)
      end

      def call(name, template, view_paths = nil)
        inherited = wrapped[template.handler]
        base = inherited || default_tracker
        base.call(name, template, view_paths) | bound_dependencies(name, template)
      end

      # Rails' default for ERB. Named `:ruby` (AST) from Rails 8.1; 7.1 and 8.0 only ship the
      # regex tracker, and ActionView.render_tracker does not exist there at all.
      def default_tracker
        # Reachable before the railtie's on_load hook has fired -- an app with eager_load
        # off has not necessarily touched ActionView::DependencyTracker yet.
        require "action_view/dependency_tracker"

        if ActionView.respond_to?(:render_tracker) && ActionView.render_tracker == :ruby
          ActionView::DependencyTracker::RubyTracker
        else
          ActionView::DependencyTracker::ERBTracker
        end
      end

      private

      # The paths this template binds, resolved the way the renderer resolves them: a name
      # with no slash is relative to the template's own directory, so `bind_render "card"`
      # inside `audit/bound` depends on `audit/card`. Reported verbatim it names a partial
      # the digestor cannot find, and the parent's fragment then survives an edit to the
      # child. Rails' ERB and Ruby trackers normalise identically.
      def bound_dependencies(name, template)
        directory = name.split("/")[0..-2].join("/")
        template.source.scan(DIRECTIVE).flatten.map do |path|
          path.include?("/") ? path : "#{directory}/#{path}"
        end
      end

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
