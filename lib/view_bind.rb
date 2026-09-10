# frozen_string_literal: true

require "concurrent/map"
require_relative "view_bind/version"
require_relative "view_bind/helper"
require_relative "view_bind/tracker"
require_relative "view_bind/profiler"
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
  # argument checking and its error message), non-ERB handlers (which may return output
  # instead of writing to the supplied buffer), and Rails whose internals we cannot reach.
  # `writes_to_buffer` lets ERB keep sharing the caller's buffer on the slow path too.
  Bound = Struct.new(:template, :method_name, :slow, :unbound_method, :writes_to_buffer)

  # resolver context => virtual path => [[locals keys, Bound], ...]
  #
  # The context is everything `find_template` consults besides the path -- the details key
  # (formats, locale, variants), the view paths and the prefixes -- plus the cache
  # generation. Keying on the details key alone is not enough: two lookup contexts that differ
  # only in view paths (a themed or tenant path, an engine, an override) or in prefixes (a
  # relative partial name rendered from two controllers) share a details key and would
  # otherwise share a template.
  #
  # The compiled method container is deliberately not part of it. A Bound holds the name of a
  # method compiled into one container, and Rails maintains exactly one per details key:
  # ActionView caches `DetailsKey.view_context_class`, and `DetailsKey.clear` drops that
  # class, the resolver caches and every details key together (lookup_context.rb). A new
  # container therefore always arrives with new details keys and new Templates. Stock `render`
  # relies on the same invariant -- a Template compiles once, and a second container built by
  # hand raises NoMethodError there too.
  #
  # A hit still allocates nothing: the composite key is built once per view per context and
  # memoised on the view by #context_for, and the array scan below runs against the inner map.
  CACHE = Concurrent::Map.new

  # Bumped by .clear_cache so that a view which already memoised a bindings map stops using
  # it. Clearing CACHE alone leaves such a view rendering the templates it resolved before.
  @generation = 0

  class << self
    # Log one summary line per request instead of Rails' one line per partial, which bound
    # partials no longer produce. Off by default; see ViewBind::Profiler.
    attr_writer :profile

    def profile? = @profile == true

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

    # This view's resolver context, memoised on the view itself: a request renders hundreds of
    # partials through the same one, and re-deriving it per call costs more than the array
    # scan it guards. Re-checked rather than assumed on every call, because a single view can
    # switch formats, variants, view paths or prefixes part-way through a render.
    #
    # The last slot holds the bindings map, so #bindings_for is a memoised read too. Building
    # the context does not touch CACHE, which lets the per-request memo in Helper key on it
    # without populating a cache that development deliberately does not use.
    def context_for(view)
      lookup = view.lookup_context
      cached = view.instance_variable_get(:@__view_bind_context)
      if cached &&
         cached[0].equal?(lookup.details_key) &&
         cached[1].equal?(lookup.view_paths) &&
         cached[2] == lookup.prefixes &&
         cached[3] == @generation
        return cached
      end

      # prefixes is a plain Array the caller owns; a copy is what makes the check above catch
      # an in-place edit, and keeps the CACHE key from rotting under one.
      context = [lookup.details_key, lookup.view_paths,
                 snapshot_prefixes(lookup.prefixes), @generation, nil]
      view.instance_variable_set(:@__view_bind_context, context)
      context
    end

    # The map of bindings resolved under this view's resolver context.
    def bindings_for(view)
      context = context_for(view)
      context[4] ||= CACHE.fetch_or_store(context[0, 4]) { Concurrent::Map.new }
    end

    # Drops every resolved template. The railtie hooks this to ActiveSupport::Reloader, so
    # a code reload cannot leave a stale template behind even in an app that turns
    # `cache_template_loading` on in development.
    def clear_cache
      # Views alive across the clear hold a memoised context pointing at a map that is about
      # to be emptied; the generation is what makes them rebuild instead of reusing it.
      @generation += 1
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

    # Copies the array *and* its strings. A shallow dup shares the elements, so a caller that
    # mutates a prefix in place -- `prefix.replace("beta")` rather than assigning a new array
    # -- would change this snapshot along with the live one, the check in #context_for would
    # see no difference, and the view would go on rendering the partial it first resolved.
    # The CACHE key holds these strings too, so they have to stop moving.
    #
    # nil passes straight through: `prefixes` is a public accessor and Rails resolves a name
    # against a nil prefix list perfectly well (see LookupContext#normalize_name), so this
    # must not be where that stops working.
    def snapshot_prefixes(prefixes)
      prefixes&.map { |prefix| prefix.frozen? ? prefix : prefix.dup.freeze }
    end

    def build(view, path, keys)
      template = resolve(view, path, keys)
      # Only the stock ERB handler is known to append to the caller's buffer. Other
      # handlers, including raw and static HTML, can return a string or a new buffer.
      writes_to_buffer = template.handler.instance_of?(ActionView::Template::Handlers::ERB)
      if template.strict_locals? || !writes_to_buffer || !fast_path_available?
        return Bound.new(template, nil, true, nil, writes_to_buffer)
      end

      template.send(:compile!, view)
      method_name = template.send(:method_name)
      # bind_call on the UnboundMethod dispatches faster than public_send, and the method
      # lives on the container, so it can be looked up once here rather than per call.
      Bound.new(template, method_name, false,
                view.compiled_method_container.instance_method(method_name), true)
    end

    def resolve(view, path, keys)
      prefix, _, name = path.rpartition("/")
      prefixes = prefix.empty? ? view.lookup_context.prefixes : [prefix]
      # find_template raises ActionView::MissingTemplate itself; there is no nil to guard.
      view.lookup_context.find_template(name, prefixes, true, keys, {})
    end
  end
end
