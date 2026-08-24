# frozen_string_literal: true

require "concurrent/map"
# PartialIteration ships with the collection renderer, which is not loaded on its own
# in an app with eager_load disabled.
require "action_view/renderer/collection_renderer"
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
module ViewBind
  # (details_key, view class, virtual path, locals shape) => ActionView::Template
  CACHE = Concurrent::Map.new

  class << self
    def template_for(view, path, keys)
      # In development ActionView::Resolver.caching? is false: resolve every time so that
      # edits to a partial are picked up without a restart. In production this runs once
      # per process, per call site.
      return resolve(view, path, keys) unless ActionView::Resolver.caching?

      # details_key covers formats, locale and variants. Leaving it out of the key means the
      # first request decides which locale of a partial every later request receives.
      key = [view.lookup_context.details_key, view.class.object_id, path, keys].freeze
      CACHE.fetch_or_store(key) { resolve(view, path, keys) }
    end

    # Clears the resolved-template cache. Rails calls this for you on reload; you only need
    # it if you swap view paths at runtime.
    def clear_cache
      CACHE.clear
    end

    private

    def resolve(view, path, keys)
      prefix, _, name = path.rpartition("/")
      prefixes = prefix.empty? ? view.lookup_context.prefixes : [prefix]
      # find_template raises ActionView::MissingTemplate itself; there is no nil to guard.
      view.lookup_context.find_template(name, prefixes, true, keys, {})
    end
  end
end
