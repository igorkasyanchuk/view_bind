# frozen_string_literal: true

require_relative "test_helper"

class ViewBindTest < Minitest::Test
  include ViewHelpers

  def setup
    ViewBind.clear_cache
    I18n.locale = :en
  end

  # ActionView::LookupContext#locale= writes I18n.locale process-wide, so a test that looks up
  # a French partial leaves every later test in French unless this runs.
  def teardown
    I18n.locale = :en
  end

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

  # Instance variables come from the view context, which is what bind_render renders into,
  # so they resolve in bound partials and in partials bound from inside them.
  def test_instance_variables_reach_nested_partials
    v = view
    v.instance_variable_set(:@who, "ada")
    v.instance_variable_set(:@depth, 2)
    v.instance_eval { bind_render "fixtures/ivar_outer" }
    assert_equal "<div>ada<em>ADA-2</em></div>", v.output_buffer.to_s.gsub(/\s+/, "")
  end

  def test_instance_variables_match_render_exactly
    bound = view
    bound.instance_variable_set(:@who, "grace")
    bound.instance_variable_set(:@depth, 7)
    bound.instance_eval { bind_render "fixtures/ivar_outer" }

    plain = view
    plain.instance_variable_set(:@who, "grace")
    plain.instance_variable_set(:@depth, 7)
    assert_equal squish(plain.render(partial: "fixtures/ivar_outer")), squish(bound.output_buffer)
  end

  # The fast path swaps @current_template / @output_buffer / @virtual_path itself, so it has
  # to put them back exactly as it found them, even when the partial raises.
  def test_restores_view_state_after_rendering
    v = view
    v.instance_eval { bind_render "fixtures/leaf", word: "a" }
    assert_nil v.instance_variable_get(:@current_template)
    assert_nil v.instance_variable_get(:@virtual_path)
  end

  def test_restores_view_state_after_an_error
    v = view
    before_buffer = v.output_buffer
    assert_raises(ActionView::Template::Error) { v.instance_eval { bind_render "fixtures/boom" } }
    assert_nil v.instance_variable_get(:@current_template)
    assert_same before_buffer, v.output_buffer
  end

  # Cached bindings hold a method compiled into the view class ActionView keeps in
  # DetailsKey. Clearing DetailsKey replaces that class and drops every details_key, so the
  # cache must miss and rebuild rather than call a method the new class does not have.
  # Stock `render` depends on the same invariant.
  def test_rebuilds_after_details_key_is_cleared
    warm = view
    warm.instance_eval { bind_render "fixtures/leaf", word: "warm" }
    before_class = warm.class

    ActionView::LookupContext::DetailsKey.clear

    after = view
    refute_equal before_class, after.class
    after.instance_eval { bind_render "fixtures/leaf", word: "after" }
    assert_equal "<i>after</i>", squish(after.output_buffer)
  end

  # The collection loop hoists the view bookkeeping outside the iteration, so it has to put
  # it back even when an item raises part-way through.
  def test_collection_restores_view_state_after_an_error
    v = view
    before_buffer = v.output_buffer
    error = assert_raises(ActionView::Template::Error) do
      v.instance_eval { bind_render_each "fixtures/boom_item", %w[a b c], as: :item }
    end
    assert_includes (error.cause || error).backtrace.first, "_boom_item.html.erb"
    assert_nil v.instance_variable_get(:@current_template)
    assert_same before_buffer, v.output_buffer
  end

  # Documented limitation, pinned so it cannot change unnoticed: these helpers append into
  # the buffer they are handed, while `render` takes the partial's return value. A partial
  # that reassigns @output_buffer without restoring it therefore renders to nothing here and
  # to markup through `render`.
  def test_a_partial_that_hijacks_the_output_buffer_renders_nothing
    v = view
    v.instance_eval { bind_render "fixtures/rude", item: "x" }
    assert_equal "", squish(v.output_buffer)

    assert_equal "<b>x</b>", squish(view.render(partial: "fixtures/rude", locals: { item: "x" }))
  end

  def test_memo_matches_plain_rendering
    memoised = view
    plain    = view
    %w[a b a b a].each do |word|
      memoised.instance_eval { bind_render_memo "fixtures/leaf", word: word }
      plain.instance_eval { bind_render "fixtures/leaf", word: word }
    end
    assert_equal squish(plain.output_buffer), squish(memoised.output_buffer)
  end

  # Only values it can compare safely are memoised. A model passed as a local must fall
  # through to a real render, or two different records that compare equal would share markup.
  def test_memo_falls_through_for_values_it_cannot_key_on
    v = view
    v.instance_eval { bind_render_memo "fixtures/stamped", word: "x", marker: Object.new }
    v.instance_eval { bind_render_memo "fixtures/stamped", word: "x", marker: Object.new }
    first, second = v.output_buffer.to_s.scan(/<i>x-(\d+)<\/i>/).flatten
    refute_equal first, second, "both renders reused one memo entry"
  end

  def test_memo_is_per_view_not_per_process
    first = view
    first.instance_eval { bind_render_memo "fixtures/leaf", word: "z" }
    second = view
    assert_nil second.instance_variable_get(:@__view_bind_memo)
  end

  # The memo is keyed by the resolved binding, which encodes the locals shape: the same
  # value under a different local name is a different partial rendering.
  def test_memo_does_not_collide_on_the_value_alone
    v = view
    v.instance_eval { bind_render_memo "fixtures/named", primary: "New" }
    v.instance_eval { bind_render_memo "fixtures/named", secondary: "New" }
    assert_equal "<i>primary=New</i><i>secondary=New</i>", v.output_buffer.to_s.gsub(/\s+/, "")
  end

  # capture returns nil for a partial that renders nothing; the memo has to record that as a
  # hit, or the partial it exists to skip is re-rendered on every call.
  def test_memo_records_a_partial_that_renders_nothing
    v = view
    2.times { v.instance_eval { bind_render_memo "fixtures/empty", word: "x" } }
    entries = v.instance_variable_get(:@__view_bind_memo).values.first
    assert entries.key?("x"), "empty render was not memoised"
    refute_nil entries["x"]
    assert_equal "", squish(v.output_buffer)
  end

  def test_memo_rejects_a_block_like_its_siblings
    v = view
    assert_raises(ArgumentError) do
      v.instance_eval { bind_render_memo("fixtures/leaf", word: "x") { "body" } }
    end
  end

  # With template caching off every call resolves a fresh binding, so an identity-keyed memo
  # would miss every time and grow an entry per call. Development renders normally instead.
  def test_memo_is_skipped_when_templates_are_not_cached
    ActionView::Resolver.caching = false
    v = view
    5.times { v.instance_eval { bind_render_memo "fixtures/leaf", word: "x" } }
    assert_nil v.instance_variable_get(:@__view_bind_memo)
    assert_equal "<i>x</i><i>x</i><i>x</i><i>x</i><i>x</i>", v.output_buffer.to_s.gsub(/\s+/, "")
  ensure
    ActionView::Resolver.caching = true
  end

  # Documented limitation, pinned: a hit appends markup without running the partial, so a
  # side effect inside it happens on the first render only.
  def test_memo_runs_side_effects_once
    memoised = view
    3.times { memoised.instance_eval { bind_render_memo "fixtures/side_effect", word: "x" } }
    assert_equal "x", memoised.content_for(:counters).to_s

    plain = view
    3.times { plain.instance_eval { bind_render "fixtures/side_effect", word: "x" } }
    assert_equal "xxx", plain.content_for(:counters).to_s
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

  def test_tracker_default_matches_the_frameworks_own
    expected = if ActionView.respond_to?(:render_tracker) && ActionView.render_tracker == :ruby
      ActionView::DependencyTracker::RubyTracker
    else
      ActionView::DependencyTracker::ERBTracker
    end
    assert_equal expected, ViewBind::Tracker.default_tracker
  end

  # Registering must extend the tracker that is already installed, not replace it: another
  # gem's ERB tracker has to keep contributing its dependencies.
  def test_tracker_chains_to_a_previously_registered_tracker
    handler = ActionView::Template.handler_for_extension(:erb)
    assert_equal ViewBind::Tracker.default_tracker, ViewBind::Tracker.wrapped[handler]
  end

  # bind_render writes to the buffer and returns nil; bind_capture is the value form.
  def test_bind_capture_returns_the_markup
    v = view
    captured = v.instance_eval { bind_capture "fixtures/greeting" }
    assert_equal "<span>hello</span>", squish(captured)
    assert_equal "", squish(v.output_buffer)
  end

  def test_bind_capture_works_with_content_for
    v = view
    v.instance_eval { content_for :side, bind_capture("fixtures/greeting") }
    assert_equal "<span>hello</span>", squish(v.content_for(:side))
    assert_equal "", squish(v.output_buffer)
  end

  # A block is not supported; dropping it silently loses content.
  def test_block_form_raises_instead_of_being_ignored
    v = view
    assert_raises(ArgumentError) { v.instance_eval { bind_render("fixtures/greeting") { "body" } } }
    assert_raises(ArgumentError) do
      v.instance_eval { bind_render_each("fixtures/item", %w[a], as: :item) { "body" } }
    end
  end

  # Requiring the gem must not drag in ActionView internals before ActiveSupport exists.
  def test_loads_without_rails
    lib = File.expand_path("../lib", __dir__)
    ok = system(RbConfig.ruby, "-I", lib, "-e", 'require "view_bind"', out: File::NULL, err: File::NULL)
    assert ok, "require \"view_bind\" failed outside of Rails"
  end
end
