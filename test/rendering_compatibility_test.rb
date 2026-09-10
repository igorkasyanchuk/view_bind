# frozen_string_literal: true

require_relative "test_helper"
require "action_view/testing/resolvers"

class RenderingCompatibilityTest < Minitest::Test
  include ViewHelpers

  HANDLER_SOURCES = {
    "raw" => "<b>kept</b>",
    "html" => "<b>kept</b>",
    "builder" => 'xml.b("kept")'
  }.freeze

  def setup
    ViewBind.clear_cache
  end

  def test_capture_preserves_blank_output_as_a_safe_string
    ["", " ", "\n", " \t\n"].each do |whitespace|
      v = template_view("erb", whitespace)
      v.output_buffer << "outside"

      result = v.bind_capture("compatibility/content")

      assert_equal whitespace, result
      assert_predicate result, :html_safe?
      assert_equal "outside", v.output_buffer.to_s
    end
  end

  def test_memo_preserves_blank_output_on_misses_and_hits
    ["", " ", "\n", " \t\n"].each do |whitespace|
      v = template_view("erb", "<% @renders = (@renders || 0) + 1 %><%= whitespace %>")
      v.output_buffer << "left"
      2.times { v.bind_render_memo("compatibility/content", whitespace: whitespace) }
      v.output_buffer << "right"

      assert_equal "left#{whitespace * 2}right", v.output_buffer.to_s
      assert_equal 1, v.instance_variable_get(:@renders)
    end
  end

  def test_capture_preserves_escaping_and_the_outer_buffer
    ["<b>word</b>", "<b>word</b>".html_safe].each do |word|
      v = template_view("erb", "<i><%= word %></i>")
      expected = v.render("compatibility/content", word: word)
      v.output_buffer << "outside"

      assert_equal expected, v.bind_capture("compatibility/content", word: word)
      assert_equal "outside", v.output_buffer.to_s
    end
  end

  def test_render_preserves_other_handlers_output
    HANDLER_SOURCES.each do |handler, source|
      v = template_view(handler, source)
      expected = v.render("compatibility/content")
      v.output_buffer << "before"

      assert_nil v.bind_render("compatibility/content")
      assert_equal "before#{expected}", v.output_buffer.to_s, handler
    end
  end

  def test_capture_preserves_other_handlers_output
    HANDLER_SOURCES.each do |handler, source|
      v = template_view(handler, source)
      expected = v.render("compatibility/content")

      assert_equal expected, v.bind_capture("compatibility/content"), handler
      assert_equal "", v.output_buffer.to_s
    end
  end

  def test_memo_preserves_other_handlers_output
    HANDLER_SOURCES.each do |handler, source|
      v = template_view(handler, source)
      expected = v.render("compatibility/content")

      2.times { assert_nil v.bind_render_memo("compatibility/content") }

      assert_equal expected * 2, v.output_buffer.to_s, handler
    end
  end

  def test_collection_preserves_other_handlers_output
    HANDLER_SOURCES.each do |handler, source|
      v = template_view(handler, source)
      expected = v.render(partial: "compatibility/content", collection: [1, 2], as: :item)
      v.output_buffer << "before"

      assert_nil v.bind_render_each("compatibility/content", [1, 2], as: :item)
      assert_equal "before#{expected}", v.output_buffer.to_s, handler
    end
  end

  def test_returning_handler_escapes_unsafe_output_once
    %i[bind_render bind_render_memo bind_render_each].each do |helper|
      ["<b>word</b>", "<b>word</b>".html_safe].each do |word|
        v = template_view("ruby", "word")
        expected = v.capture { v.output_buffer << v.render("compatibility/content", word: word) }

        if helper == :bind_render_each
          v.bind_render_each("compatibility/content", [word, word], as: :word)
        else
          2.times { v.public_send(helper, "compatibility/content", word: word) }
        end

        assert_equal expected * 2, v.output_buffer.to_s, helper
      end
    end
  end

  def test_returning_handler_receives_collection_locals
    source = %q{"<b>#{label}:#{item}@#{item_counter}/#{item_iteration.size}</b>".html_safe}
    v = template_view("ruby", source)
    expected = v.render(partial: "compatibility/content", collection: %w[a b], as: :item,
                        locals: { label: "item" })

    v.bind_render_each("compatibility/content", %w[a b], as: :item, label: "item")

    assert_equal "<b>item:a@0/2</b><b>item:b@1/2</b>", v.output_buffer.to_s
    assert_equal expected, v.output_buffer.to_s
  end

  def test_memo_preserves_signed_zero_in_single_and_composite_keys
    [[0.0, -0.0], [-0.0, 0.0]].each do |values|
      [{}, { label: "number" }].each do |shared|
        v = template_view("erb", "<%= number %>")
        expected = values.map { |number| v.render("compatibility/content", **shared, number: number) }.join

        values.each { |number| v.bind_render_memo("compatibility/content", **shared, number: number) }

        assert_equal expected, v.output_buffer.to_s
      end
    end
  end

  def test_memo_still_reuses_nonzero_floats
    v = template_view("erb", "<% @renders = (@renders || 0) + 1 %><%= number %>")

    2.times { v.bind_render_memo("compatibility/content", number: 1.5) }

    assert_equal "1.51.5", v.output_buffer.to_s
    assert_equal 1, v.instance_variable_get(:@renders)
  end

  def test_strict_locals_still_reject_missing_arguments
    v = template_view("erb", "<%# locals: (word:) %><%= word %>")

    assert_raises(ActionView::Template::Error) { v.bind_render("compatibility/content") }
    assert_equal "", v.output_buffer.to_s
  end

  def test_strict_locals_render_reuses_the_callers_buffer
    v = template_view("erb", "<%# locals: (word:) %><% @render_buffer = output_buffer %><%= word %>")
    buffer = v.output_buffer
    buffer << "before"

    assert_nil v.bind_render("compatibility/content", word: "<b>word</b>")

    assert_same buffer, v.instance_variable_get(:@render_buffer)
    assert_same buffer, v.output_buffer
    assert_equal "before&lt;b&gt;word&lt;/b&gt;", buffer.to_s
  end

  def test_strict_locals_collection_reuses_the_buffer_with_optional_iteration_locals
    ["item:", "item:, item_iteration:", "item:, item_counter:, item_iteration:"].each do |signature|
      source = "<%# locals: (#{signature}) -%>\n" \
               "<% (@render_buffers ||= []) << output_buffer %><%= item %>"
      v = template_view("erb", source)
      buffer = v.output_buffer
      buffer << "before"

      assert_nil v.bind_render_each("compatibility/content", %w[a b], as: :item)

      assert_equal "beforeab", buffer.to_s
      assert_same buffer, v.output_buffer
      buffers = v.instance_variable_get(:@render_buffers)
      assert_equal 2, buffers.size
      buffers.each { |render_buffer| assert_same buffer, render_buffer }
    end
  end

  def test_erb_reuses_the_buffer_when_the_direct_call_is_unavailable
    previous = ViewBind.instance_variable_get(:@fast_path_available)
    ViewBind.instance_variable_set(:@fast_path_available, false)
    v = template_view("erb", "<% (@render_buffers ||= []) << output_buffer %><%= word %>")
    buffer = v.output_buffer

    assert_nil v.bind_render("compatibility/content", word: "a")
    assert_nil v.bind_render_each("compatibility/content", %w[b c], as: :word)

    assert_equal "abc", buffer.to_s
    assert_same buffer, v.output_buffer
    buffers = v.instance_variable_get(:@render_buffers)
    assert_equal 3, buffers.size
    buffers.each { |render_buffer| assert_same buffer, render_buffer }
  ensure
    ViewBind.instance_variable_set(:@fast_path_available, previous)
    ViewBind.clear_cache
  end

  def test_returning_handler_restores_view_state_after_an_error
    %i[bind_render bind_render_each].each do |helper|
      v = template_view("ruby", 'raise "broken handler"')
      buffer = v.output_buffer
      v.output_buffer << "before"

      error = assert_raises(ActionView::Template::Error) do
        if helper == :bind_render_each
          v.bind_render_each("compatibility/content", [1], as: :item)
        else
          v.bind_render("compatibility/content")
        end
      end

      assert_match(/broken handler/, error.message)
      assert_same buffer, v.output_buffer
      assert_nil v.instance_variable_get(:@current_template)
      assert_nil v.instance_variable_get(:@virtual_path)
      assert_equal "before", v.output_buffer.to_s
    end
  end

  private

  def template_view(handler, source)
    resolver = ActionView::FixtureResolver.new("compatibility/_content.html.#{handler}" => source)
    view.tap { |v| v.lookup_context.prepend_view_paths([resolver]) }
  end
end
