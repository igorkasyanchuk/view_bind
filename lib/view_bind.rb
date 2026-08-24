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
  # A resolved partial. `slow` means render it through ActionView::Template#render rather
  # than by calling its compiled method: strict-locals partials (Template#render owns the
  # argument checking and its error message) and any Rails whose internals this gem cannot
  # reach.
  Bound = Struct.new(:template, :method_name, :slow)

  # details_key => virtual path => [[locals keys, Bound], ...]
  #
  # Nested maps rather than one map keyed by a composite array: a hit allocates nothing.
  # details_key covers formats, locale and variants.
  #
  # A Bound holds the name of a method compiled into one view class's compiled method
  # container, which is safe because Rails maintains exactly one: ActionView caches
  # `DetailsKey.view_context_class`, and `DetailsKey.clear` drops that class, the resolver
  # caches and every details_key together (lookup_context.rb). A new container therefore
  # always arrives with new details keys, which miss this cache and rebuild. Stock `render`
  # relies on the same invariant -- a Template compiles once, and calling it from a second
  # container raises NoMethodError there too.
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
        # compute is atomic: two threads first-rendering the same partial with different
        # locals cannot lose each other's entry.
        by_path.compute(path) { |existing| (existing || []) + [[keys, bound]] }
      end
    end

    # Same lookup, taking the locals hash instead of its keys: a hit compares against the
    # cached key array in place, so the common path allocates nothing at all. `keys` is only
    # materialised when the partial has to be resolved.
    def bound_for_locals(view, path, locals)
      return build(view, path, locals.keys) unless ActionView::Resolver.caching?

      entries = bindings_for(view)[path]
      entries&.each do |keys, bound|
        return bound if keys.size == locals.size && keys.all? { |key| locals.key?(key) }
      end

      bound_for(view, path, locals.keys)
    end

    # The map for this view's container and lookup details, memoised on the view itself: a
    # request renders hundreds of partials through the same pair, and re-deriving it per call
    # costs more than the array scan it guards. Compared by identity -- a single view can
    # switch formats or variants part-way through a render.
    def bindings_for(view)
      details_key = view.lookup_context.details_key
      cached      = view.instance_variable_get(:@__view_bind_bindings)
      return cached[1] if cached && cached[0].equal?(details_key)

      CACHE.fetch_or_store(details_key) { Concurrent::Map.new }.tap do |map|
        view.instance_variable_set(:@__view_bind_bindings, [details_key, map])
      end
    end

    # Drops every resolved template. The railtie hooks this to ActiveSupport::Reloader, so
    # a code reload cannot leave a stale template behind even in an app that turns
    # `cache_template_loading` on in development.
    def clear_cache
      CACHE.clear
    end

    # The fast path calls three of ActionView::Template's :nodoc: methods. If a future Rails
    # renames one, every partial quietly goes back through Template#render instead of
    # raising NoMethodError on the first request after the upgrade.
    def fast_path_available?
      return @fast_path_available unless @fast_path_available.nil?

      @fast_path_available = %i[compile! method_name handle_render_error].all? do |method|
        ActionView::Template.private_method_defined?(method) ||
          ActionView::Template.method_defined?(method)
      end
    end

    private

    def build(view, path, keys)
      template = resolve(view, path, keys)
      return Bound.new(template, nil, true) if template.strict_locals? || !fast_path_available?

      template.send(:compile!, view)
      Bound.new(template, template.send(:method_name), false)
    end

    def resolve(view, path, keys)
      prefix, _, name = path.rpartition("/")
      prefixes = prefix.empty? ? view.lookup_context.prefixes : [prefix]
      # find_template raises ActionView::MissingTemplate itself; there is no nil to guard.
      view.lookup_context.find_template(name, prefixes, true, keys, {})
    end
  end
end
