# frozen_string_literal: true

module ViewBind
  # Helpers available in every view, partial and layout.
  module Helper
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
      # Strict-locals partials go through Template#render, which owns the argument checking
      # and the StrictLocalsError message; everything else calls the compiled method.
      if bound.slow
        bound.template.render(self, locals, output_buffer)
      else
        bind_run(bound, locals, output_buffer)
      end
      nil
    end

    # Render a partial and return its HTML instead of writing it to the buffer.
    #
    #   <% content_for :sidebar, bind_capture("shared/widget") %>
    def bind_capture(path, **locals)
      capture { bind_render(path, **locals) }
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
      method_name       = bound.method_name

      begin
        collection.each do |item|
          locals[as]      = item
          locals[counter] = partial_iteration.index
          public_send(method_name, locals, buffer)
          partial_iteration.iterate!
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

    # Mirrors ActionView::Base#_run. This lives in the helper, which is included in the view
    # class, so it can save and restore the view's own ivars directly -- going through
    # instance_variable_get/set costs more than the render it is wrapping.
    def bind_run(bound, locals, buffer)
      previous_buffer   = @output_buffer
      previous_path     = @virtual_path
      previous_template = @current_template

      @current_template = bound.template
      @output_buffer    = buffer
      public_send(bound.method_name, locals, buffer)
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
