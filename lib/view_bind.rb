# frozen_string_literal: true

require "concurrent/map"
require_relative "view_bind/version"
require_relative "view_bind/helper"
require_relative "view_bind/tracker"
require_relative "view_bind/railtie" if defined?(Rails::Railtie)

# ViewBind renders a partial by calling the method Rails already compiled for it,
# instead of walking the full `render` path on every call.
#
# What is skipped per call: the options hash, a fresh PartialRenderer, extract_details,
# the template lookup, the ActiveSupport notification, a per-partial OutputBuffer and the
# string copy out of it. What is NOT skipped: the partial is still an ordinary compiled
# template, so backtraces name the real file and line, `local_assigns` works, strict locals
# work, development reloading works and fragment cache digests still bust.
#
# Nothing here requires ActionView at load time: the gem may be required before Rails.
module ViewBind
  # A resolved partial: the template, the name of the method Rails compiled it into, and
  # whether it declares strict locals (those go back through Template#render, which owns the
  # argument checking and its error message).
  Bound = Struct.new(:template, :method_name, :strict)

  # details_key => Concurrent::Map(virtual path => [[locals keys, Bound], ...])
  #
  # Two levels of map and a tiny array scan, rather than one map keyed by a composite array:
  # a hit then allocates nothing at all. details_key covers formats, locale and variants;
  # leaving it out means the first request decides which locale every later request gets.
  CACHE = Concurrent::Map.new

  class << self
    def bound_for(view, path, keys)
      # In development ActionView::Resolver.caching? is false: resolve every time so that
      # edits to a partial are picked up without a restart.
      return build(view, path, keys) unless ActionView::Resolver.caching?

      by_path = bindings_for(view)
      entries = by_path[path]
      entries&.each { |keys_for_entry, bound| return bound if keys_for_entry == keys }

      build(view, path, keys).tap do |bound|
        # Copy on write: readers always see a complete array, whatever the thread.
        by_path[path] = (entries || []) + [[keys, bound]]
      end
    end

    # Drops every resolved template. The railtie hooks this to ActiveSupport::Reloader, so
    # a code reload cannot leave a stale template behind even in an app that turns
    # `cache_template_loading` on in development.
    def clear_cache
      CACHE.clear
    end

    # The map for this view's current lookup details, memoised on the view itself: a request
    # renders hundreds of partials through the same details_key, and re-deriving it per call
    # costs more than the array scan it guards. Re-checked by identity, because a single view
    # can switch formats or variants part-way through a render.
    def bindings_for(view)
      details_key = view.lookup_context.details_key
      cached = view.instance_variable_get(:@__view_bind_bindings)
      return cached[1] if cached && cached[0].equal?(details_key)

      CACHE.fetch_or_store(details_key) { Concurrent::Map.new }.tap do |map|
        view.instance_variable_set(:@__view_bind_bindings, [details_key, map])
      end
    end

    private

    def build(view, path, keys)
      template = resolve(view, path, keys)
      template.send(:compile!, view)
      Bound.new(template, template.send(:method_name), template.strict_locals?)
    end

    def resolve(view, path, keys)
      prefix, _, name = path.rpartition("/")
      prefixes = prefix.empty? ? view.lookup_context.prefixes : [prefix]
      # find_template raises ActionView::MissingTemplate itself; there is no nil to guard.
      view.lookup_context.find_template(name, prefixes, true, keys, {})
    end
  end
end
