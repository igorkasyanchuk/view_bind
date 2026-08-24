# frozen_string_literal: true

module ViewBind
  # Helpers available in every view, partial and layout.
  module Helper
    # Render a partial by calling its own compiled method, straight into the current buffer.
    #
    #   <%= bind_render "shared/header" %>
    #   <%= bind_render "posts/card", post: post %>
    #
    # Returns nil: the partial writes itself into the buffer, so `<%= %>` appends nothing.
    def bind_render(path, **locals)
      ViewBind.template_for(self, path, locals.keys).render(self, locals, output_buffer)
      nil
    end

    # Collection form. Resolves once, then one render per item reusing a single locals hash,
    # the same way ActionView's own CollectionRenderer does.
    #
    #   <%= bind_render_each "posts/card", @posts, as: :post %>
    #
    # Provides `<as>_counter` and `<as>_iteration` exactly like `render collection:`.
    def bind_render_each(path, collection, as:, **shared)
      collection = collection.to_a
      locals     = shared.dup
      counter    = :"#{as}_counter"
      iteration  = :"#{as}_iteration"
      template   = ViewBind.template_for(self, path, locals.keys + [as, counter, iteration])
      buffer     = output_buffer

      partial_iteration = ActionView::PartialIteration.new(collection.size)
      locals[iteration] = partial_iteration

      collection.each do |item|
        locals[as]      = item
        locals[counter] = partial_iteration.index
        template.render(self, locals, buffer, implicit_locals: [counter, iteration])
        partial_iteration.iterate!
      end
      nil
    end
  end
end
