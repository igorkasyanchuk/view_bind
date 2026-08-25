# frozen_string_literal: true

module ViewBind
  # Helpers available in every view, partial and layout.
  module Helper
    # Cap on distinct memo entries per partial, per locals shape, per set of lookup details.
    # The memo dies with the request, so this only bounds a single page built from an
    # unbounded set of locals values.
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

      bound = ViewBind.bound_for_locals(self, path, locals)
      return (render_bound(bound, locals); nil) unless ViewBind.profile?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      render_bound(bound, locals)
      ViewBind::Profiler.record(path, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
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

      values = locals.values
      # No block, no intermediate array: the type test is on the hot path of every call.
      i = 0
      while i < values.size
        case values[i]
        when String, Symbol, Numeric, true, false, nil then i += 1
        else return bind_render(path, **locals)
        end
      end

      # Keyed by lookup details, then path, then the locals names, then their values.
      #
      # details_key covers formats, locale and variants: without it, a partial memoised
      # before `lookup_context.variants = [:phone]` or inside `I18n.with_locale` keeps
      # serving the markup it was first rendered with. The names matter too --
      # `primary: "New"` and `secondary: "New"` are different renderings of one partial.
      #
      # Keying this way rather than by the resolved binding means a hit does not resolve the
      # template at all, and behaves identically whether or not templates are cached, so a
      # partial with a side effect cannot behave one way in development and another in
      # production.
      memo     = (@__view_bind_memo ||= {}.compare_by_identity)
      by_path  = (memo[lookup_context.details_key] ||= {})
      by_shape = (by_path[path] ||= {})
      by_value = (by_shape[locals.keys] ||= {})
      # One local is overwhelmingly the common case, and a bare value keys far cheaper than
      # an array: no allocation, no array hashing.
      key = values.size == 1 ? values[0] : values

      if by_value.key?(key)
        html = by_value[key]
      else
        # capture returns nil for a partial that renders nothing; store the empty buffer so
        # key? still reports a hit and it is not re-rendered on every call.
        html = capture { bind_render(path, **locals) } || ActiveSupport::SafeBuffer.new
        by_value[key] = html if by_value.size < MEMO_LIMIT_PER_SHAPE
      end

      output_buffer << html
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
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC) if ViewBind.profile?

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

      begin
        collection.each do |item|
          locals[as]      = item
          locals[counter] = partial_iteration.index
          render_method.bind_call(self, locals, buffer)
          partial_iteration.iterate!
        end
      rescue StandardError => e
        bound.template.send(:handle_render_error, self, e)
      ensure
        @output_buffer    = previous_buffer
        @virtual_path     = previous_path
        @current_template = previous_template
        if started
          ViewBind::Profiler.record(path, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                                    collection.size)
        end
      end
      nil
    end

    private

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
