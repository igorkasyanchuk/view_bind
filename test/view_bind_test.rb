# frozen_string_literal: true

require_relative "test_helper"

class ViewBindTest < Minitest::Test
  include ViewHelpers

  def setup = ViewBind.clear_cache

  def test_matches_what_render_produces
    v = view
    expected = v.render(partial: "fixtures/greeting")
    v.instance_eval { bind_render "fixtures/greeting" }
    assert_equal squish(expected), squish(v.output_buffer)
  end

  def test_passes_locals
    v = view
    v.instance_eval { bind_render "fixtures/leaf", word: "ok" }
    assert_equal "<i>ok</i>", squish(v.output_buffer)
  end

  def test_supports_strict_locals
    v = view
    v.instance_eval { bind_render "fixtures/strict", name: "Ada" }
    assert_equal "<b>Ada</b>", squish(v.output_buffer)
  end

  def test_collection_provides_counter_and_iteration
    v = view
    v.instance_eval { bind_render_each "fixtures/item", %w[a b], as: :item }
    assert_equal "<li>a@0/2</li> <li>b@1/2!</li>", squish(v.output_buffer)
  end

  def test_collection_matches_render_collection
    a = view.tap { |v| v.instance_eval { bind_render_each "fixtures/item", %w[x y z], as: :item } }
    b = view.render(partial: "fixtures/item", collection: %w[x y z], as: :item)
    assert_equal squish(b), squish(a.output_buffer)
  end

  # The bug this gem must not have: a cache key that ignores lookup details serves the
  # first-resolved locale to everyone.
  def test_respects_locale
    en = view(locale: :en)
    fr = view(locale: :fr)
    en.instance_eval { bind_render "fixtures/greeting" }
    fr.instance_eval { bind_render "fixtures/greeting" }
    assert_equal "<span>hello</span>", squish(en.output_buffer)
    assert_equal "<span>bonjour</span>", squish(fr.output_buffer)
  end

  def test_missing_partial_raises_missing_template
    v = view
    assert_raises(ActionView::MissingTemplate) { v.instance_eval { bind_render "fixtures/nope" } }
  end

  # Backtraces are correct by construction: Rails compiled the partial with its own
  # identifier and offset, and we call that method.
  def test_backtrace_points_at_the_partial
    v = view
    error = assert_raises(ActionView::Template::Error) { v.instance_eval { bind_render "fixtures/boom" } }
    frame = (error.cause || error).backtrace.first
    assert_includes frame, "fixtures/_boom.html.erb:2"
  end

  def test_works_in_a_layout_and_nested_partials
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host = "localhost"
    session.get "/page"
    assert_equal 200, session.response.status
    assert_equal "<html><body><span>hello</span><main><p><i>deep</i></p></main></body></html>",
                 session.response.body.gsub(/\s+/, "")
  end

  # Editing a bound partial must change the digest of every template that binds it,
  # otherwise `cache` blocks upstream serve stale HTML.
  def test_dependency_tracking_busts_fragment_digests
    leaf = Rails.root.join("views/fixtures/_leaf.html.erb")
    original = File.read(leaf)
    finder = -> { view.lookup_context }
    digest = -> { ActionView::Digestor.digest(name: "fixtures/page", format: :html, finder: finder.call) }

    before = digest.call
    File.write(leaf, "#{original}<!-- changed -->")
    ActionView::LookupContext::DetailsKey.clear
    after = digest.call

    refute_equal before, after
  ensure
    File.write(leaf, original)
    ActionView::LookupContext::DetailsKey.clear
  end

  def test_tracker_delegates_to_the_configured_base
    expected = if ActionView.respond_to?(:render_tracker) && ActionView.render_tracker == :ruby
      ActionView::DependencyTracker::RubyTracker
    else
      ActionView::DependencyTracker::ERBTracker
    end
    assert_equal expected, ViewBind::Tracker.base
  end
end
