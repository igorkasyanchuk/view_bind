# frozen_string_literal: true

module ViewBind
  # Helpers available in every view, partial and layout.
  module Helper
    # Cap on distinct memo entries per partial, per locals shape, per HTML-safety mask, per
    # resolver context. The memo dies with the request, so this only bounds a single page
    # built from an unbounded set of locals values.
    #
    # The mask is part of what is counted, so a partial whose locals arrive sometimes
    # html_safe and sometimes not can hold this many entries per mask it actually sees.
    # Counting across masks instead would put a sum over the mask table on the hot path of
    # every call, which costs more than the bound is worth: the masks a call site produces
    # are bounded by 2**locals.size and the whole memo dies with the request.
    MEMO_LIMIT_PER_SHAPE = 512
    # Render a partial by calling its own compiled method, straight into the current buffer.
    #
    #   <%= bind_render "shared/header" %>
    #   <%= bind_render "posts/card", post: post %>
    #
    # Writes into the buffer and returns nil, so `<%= %>` appends nothing extra. When you
    # need the markup as a value -- `content_for(:side, ...)`, a helper argument -- use
    # #bind_capture, which returns a string.
    def bind_render(path, **locals, &block)
      raise ArgumentError, "bind_render does not support a block; use render for the block form" if block

      unless ViewBind.profile?
        render_bound(ViewBind.bound_for_locals(self, path, locals), locals)
        return nil
      end

      # The lookup is part of what a call costs, so it is inside the measurement.
      ViewBind::Profiler.measure(path) do
        render_bound(ViewBind.bound_for_locals(self, path, locals), locals)
      end
      nil
    end

    # Render a partial and return its HTML instead of writing it to the buffer.
    #
    #   <% content_for :sidebar, bind_capture("shared/widget") %>
    def bind_capture(path, **locals)
      capture { bind_render(path, **locals) }
    end

    # Render a partial once per distinct set of locals *values*, reusing the markup for
    # every repeat within this request.
    #
    #   <%= bind_render_memo "shared/tag", tag: tag %>
    #
    # For a partial that is a pure function of its locals -- no ivars, no `Time.now`, no
    # counters, nothing but the values passed in -- this collapses hundreds of renders into
    # a handful. A page listing 600 tags drawn from eight distinct strings renders eight.
    #
    # A hit appends the stored markup without running the partial, so anything the partial
    # does besides producing markup happens once: `content_for`, `provide`, incrementing an
    # ivar, registering an asset. Memoise markup, not side effects.
    #
    # Only values it can safely compare are memoised (String, Symbol, Numeric, true, false,
    # nil); anything else -- a model, a hash, an array -- falls through to a normal render,
    # so passing a record cannot serve you a stale card. The memo lives on the view, so it
    # dies with the request: a partial that reads I18n.locale or current_user through a
    # helper is still correct, because a request has only one of each.
    def bind_render_memo(path, **locals, &block)
      raise ArgumentError, "bind_render_memo does not support a block" if block
      # The key walk is part of what a memo call costs -- that is the number worth comparing
      # against the render it replaces -- so it happens inside the measurement.
      return (memo_render(path, locals); nil) unless ViewBind.profile?

      ViewBind::Profiler.measure_memo(path) { memo_render(path, locals) }
      nil
    end

    # Collection form. Resolves once, then one render per item reusing a single locals hash,
    # the same way ActionView's own CollectionRenderer does.
    #
    #   <%= bind_render_each "posts/card", @posts, as: :post %>
    #
    # Provides `<as>_counter` and `<as>_iteration` exactly like `render collection:`.
    def bind_render_each(path, collection, as:, **shared, &block)
      raise ArgumentError, "bind_render_each does not support a block" if block

      # PartialIteration ships with the collection renderer, which an app with eager_load
      # disabled has not necessarily loaded yet. Required here rather than at gem load time,
      # so that requiring view_bind before Rails cannot blow up.
      require "action_view/renderer/collection_renderer" unless defined?(ActionView::PartialIteration)

      collection = collection.to_a
      locals     = shared.dup
      counter    = :"#{as}_counter"
      iteration  = :"#{as}_iteration"
      bound      = ViewBind.bound_for(self, path, locals.keys + [as, counter, iteration])
      buffer     = output_buffer

      partial_iteration = ActionView::PartialIteration.new(collection.size)
      locals[iteration] = partial_iteration


      if bound.slow
        collection.each do |item|
          locals[as]      = item
          locals[counter] = partial_iteration.index
          bound.template.render(self, locals, buffer, implicit_locals: [counter, iteration])
          partial_iteration.iterate!
        end
        return nil
      end

      # Every item renders the same template, so the view bookkeeping is saved and restored
      # once for the whole collection instead of once per item.
      previous_buffer   = @output_buffer
      previous_path     = @virtual_path
      previous_template = @current_template
      @current_template = bound.template
      @output_buffer    = buffer
      render_method     = bound.unbound_method

      each_item = lambda do
        collection.each do |item|
          locals[as]      = item
          locals[counter] = partial_iteration.index
          render_method.bind_call(self, locals, buffer)
          partial_iteration.iterate!
        end
      end

      begin
        if ViewBind.profile?
          ViewBind::Profiler.measure(path, count: collection.size) { each_item.call }
        else
          each_item.call
        end
      rescue StandardError => e
        bound.template.send(:handle_render_error, self, e)
      ensure
        @output_buffer    = previous_buffer
        @virtual_path     = previous_path
        @current_template = previous_template
      end
      nil
    end

    private

    # Walks the memo, appends the markup and reports what happened: true for a hit, false for
    # a miss, :delegated when the locals cannot be keyed on and the call went to bind_render,
    # which measures itself.
    def memo_render(path, locals)
      values = locals.values
      # No block, no intermediate array: the type test is on the hot path of every call.
      #
      # `safety` records which values are html_safe. A SafeBuffer and an equal plain String
      # are eql? and hash alike, but ERB escapes only the plain one, so they must not share a
      # memo entry: whichever rendered first would decide the escaping for both, and markup
      # meant to be escaped would be emitted raw. Keying on a separate mask rather than on a
      # marker inside the value allocates nothing per call, and cannot be forged by a local
      # that happens to start with the marker. A SafeBuffer whose html_safe? is false escapes
      # exactly like a String, so it shares.
      safety = 0
      i = 0
      while i < values.size
        case (value = values[i])
        when String
          safety |= (1 << i) if value.html_safe?
          i += 1
        when Symbol, Numeric, true, false, nil then i += 1
        else
          bind_render(path, **locals)
          return :delegated
        end
      end

      # Keyed by resolver context, then path, then the locals names, then which of them are
      # html_safe, then their values.
      #
      # The context covers formats, locale, variants, view paths and prefixes: without it, a
      # partial memoised before `lookup_context.variants = [:phone]`, inside
      # `I18n.with_locale`, or under a different view path keeps serving the markup it was
      # first rendered with. The names matter too -- `primary: "New"` and `secondary: "New"`
      # are different renderings of one partial. A view that leaves a context and comes back
      # to it gets a fresh context object and so an empty memo, which re-renders rather than
      # serving anything stale.
      memo      = (@__view_bind_memo ||= {}.compare_by_identity)
      by_path   = (memo[ViewBind.context_for(self)] ||= {})
      by_shape  = (by_path[path] ||= {})
      by_safety = (by_shape[locals.keys] ||= {})
      by_value  = (by_safety[safety] ||= {})
      # One local is overwhelmingly the common case, and a bare value keys far cheaper than
      # an array: no allocation, no array hashing.
      key = values.size == 1 ? values[0] : values
      hit = by_value.key?(key)

      output_buffer << memo_fetch(by_value, key, hit, path, locals)
      hit
    end

    # Returns the memoised markup, rendering and storing it on a miss. Rendering goes through
    # the resolved binding rather than bind_render, so the profiler counts the call once.
    def memo_fetch(by_value, key, hit, path, locals)
      return by_value[key] if hit

      bound = ViewBind.bound_for_locals(self, path, locals)
      # capture returns nil for a partial that renders nothing; store the empty buffer so
      # key? still reports a hit and it is not re-rendered on every call.
      rendered = capture { render_bound(bound, locals) } || ActiveSupport::SafeBuffer.new
      by_value[memo_key_snapshot(key)] = rendered if by_value.size < MEMO_LIMIT_PER_SHAPE
      rendered
    end

    # Hash copies and freezes a key of its own accord only when that key's class is exactly
    # String -- not a SafeBuffer, and not a String held inside an Array key. Anything the
    # caller could still mutate therefore gets its own frozen copy here, or a later `<<` on
    # the value that was passed would move the stored entry out of its own bucket. Only the
    # miss path pays for this; a lookup goes on using the caller's value, which hashes the
    # same. Copying a bare String too costs nothing, since it is the copy Hash would make.
    def memo_key_snapshot(key)
      case key
      when Array  then key.map { |value| memo_key_snapshot(value) }
      when String then key.frozen? ? key : key.dup.freeze
      else key
      end
    end

    # Strict-locals partials go through Template#render, which owns the argument checking
    # and the StrictLocalsError message; everything else calls the compiled method.
    def render_bound(bound, locals)
      if bound.slow
        bound.template.render(self, locals, output_buffer)
      else
        bind_run(bound, locals, output_buffer)
      end
    end

    # Mirrors ActionView::Base#_run. This lives in the helper, which is included in the view
    # class, so it can save and restore the view's own ivars directly -- going through
    # instance_variable_get/set costs more than the render it is wrapping.
    def bind_run(bound, locals, buffer)
      previous_buffer   = @output_buffer
      previous_path     = @virtual_path
      previous_template = @current_template

      @current_template = bound.template
      @output_buffer    = buffer
      bound.unbound_method.bind_call(self, locals, buffer)
      nil
    rescue StandardError => e
      # Same wrapping Template#render does, so the error page still names the partial.
      bound.template.send(:handle_render_error, self, e)
    ensure
      @output_buffer    = previous_buffer
      @virtual_path     = previous_path
      @current_template = previous_template
    end
  end
end
