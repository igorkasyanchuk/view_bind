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
    assert_equal "<div>ada<em>ADA-2</em></div>", dense(v.output_buffer)
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
    assert_equal "<i>primary=New</i><i>secondary=New</i>", dense(v.output_buffer)
  end

  # capture returns nil for a partial that renders nothing; the memo has to record that as a
  # hit, or the partial it exists to skip is re-rendered on every call.
  def test_memo_records_a_partial_that_renders_nothing
    v = view
    2.times { v.instance_eval { bind_render_memo "fixtures/empty", word: "x" } }
    entries = memo_entries(v)
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

  # The memo must behave the same whether or not templates are cached: a partial with a side
  # effect that runs once in production and three times in development is a bug you only meet
  # after deploying.
  def test_memo_behaves_the_same_with_and_without_template_caching
    was = ActionView::Resolver.caching?
    results = [true, false].map do |caching|
      ActionView::Resolver.caching = caching
      ViewBind.clear_cache
      v = view
      3.times { v.instance_eval { bind_render_memo "fixtures/side_effect", word: "x" } }
      [v.content_for(:counters).to_s, dense(v.output_buffer)]
    end
    assert_equal results.first, results.last
  ensure
    ActionView::Resolver.caching = was
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

  # Lookup details are part of the memo key: switching variant (or locale) mid-render must
  # not keep serving the markup the partial was first rendered with.
  def test_memo_respects_a_variant_change
    memoised = view
    memoised.instance_eval { bind_render_memo "fixtures/variantish", word: "x" }
    memoised.lookup_context.variants = [:phone]
    memoised.instance_eval { bind_render_memo "fixtures/variantish", word: "x" }

    plain = view
    plain.instance_eval { bind_render "fixtures/variantish", word: "x" }
    plain.lookup_context.variants = [:phone]
    plain.instance_eval { bind_render "fixtures/variantish", word: "x" }

    assert_equal dense(plain.output_buffer), dense(memoised.output_buffer)
    assert_equal "<i>desktop-x</i><i>phone-x</i>", dense(memoised.output_buffer)
  end

  # Bound partials emit no render_partial events, so the profiler is the replacement for the
  # per-partial log lines. Off by default, and it must stay off unless asked.
  def test_profiler_is_off_by_default
    ViewBind::Profiler.reset
    v = view
    3.times { v.instance_eval { bind_render "fixtures/leaf", word: "x" } }
    assert_nil ViewBind::Profiler.summary
  end

  def test_profiler_counts_calls_and_collections
    ViewBind.profile = true
    ViewBind::Profiler.reset
    v = view
    2.times { v.instance_eval { bind_render "fixtures/leaf", word: "x" } }
    v.instance_eval { bind_render_each "fixtures/item", %w[a b c], as: :item }

    summary = ViewBind::Profiler.summary
    assert_match(/ViewBind: 5 calls/, summary)
    assert_match(/fixtures\/leaf\s+x2/, summary)
    assert_match(/fixtures\/item\s+x3/, summary)
    assert_equal summary, ViewBind::Profiler.summary, "summary must be a pure read"
  ensure
    ViewBind.profile = false
    ViewBind::Profiler.reset
  end

  # A memo hit renders nothing, but it is still a call: reporting a partial used 600 times as
  # x1 would hide exactly what the profiler exists to show.
  def test_profiler_counts_memo_hits
    ViewBind.profile = true
    ViewBind::Profiler.reset
    v = view
    5.times { v.instance_eval { bind_render_memo "fixtures/leaf", word: "x" } }

    summary = ViewBind::Profiler.summary
    assert_match(/ViewBind: 5 calls/, summary)
    assert_match(/\(4 memo\)/, summary)
  ensure
    ViewBind.profile = false
    ViewBind::Profiler.reset
  end

  # A parent's duration already contains its children's, so the header must total only the
  # outermost calls -- otherwise every nested partial is counted twice.
  def test_profiler_total_does_not_double_count_nesting
    ViewBind.profile = true
    ViewBind::Profiler.reset
    v = view
    v.instance_eval { bind_render "fixtures/parent", word: "deep" }   # parent renders leaf

    summary = ViewBind::Profiler.summary
    header  = summary.lines.first[/([\d.]+)ms/, 1].to_f
    parent  = summary.lines.find { |l| l.include?("fixtures/parent") }[/([\d.]+)ms/, 1].to_f
    leaf    = summary.lines.find { |l| l.include?("fixtures/leaf") }[/([\d.]+)ms/, 1].to_f

    assert_operator leaf, :>, 0, "the nested partial should be timed"
    assert_in_delta parent, header, 0.01, "header should be the outermost call, not a sum"
    assert_operator header, :<, parent + leaf, "nested time was counted twice"
  ensure
    ViewBind.profile = false
    ViewBind::Profiler.reset
  end

  # A local the memo cannot key on is handed to bind_render, which measures itself. The memo
  # must not record it again, or one render would show as two calls.
  def test_profiler_counts_a_delegated_memo_call_once
    ViewBind.profile = true
    ViewBind::Profiler.reset
    v = view
    v.instance_eval { bind_render_memo "fixtures/leaf", word: ["not", "keyable"] }

    summary = ViewBind::Profiler.summary
    assert_match(/ViewBind: 1 calls/, summary)
    # The header totals outermost calls only. This call is outermost, so timing it one level
    # deeper would leave the header at 0.00ms while the row showed the real elapsed time.
    header = summary.lines.first[/([\d.]+)ms/, 1].to_f
    row    = summary.lines[1][/([\d.]+)ms/, 1].to_f
    assert_in_delta row, header, 0.01, "the delegated render did not reach the header total"
    assert_operator header, :>, 0
  ensure
    ViewBind.profile = false
    ViewBind::Profiler.reset
  end

  # --- resolver context -------------------------------------------------------------------
  #
  # A details key covers formats, locale and variants, and nothing else. Two lookup contexts
  # that differ only in view paths or prefixes share one, so a cache keyed on it alone hands
  # the second context the first one's template.

  def test_respects_view_paths
    plain = view
    themed = view
    themed.lookup_context.prepend_view_paths([alt_view_path])

    plain.instance_eval { bind_render "fixtures/leaf", word: "x" }
    themed.instance_eval { bind_render "fixtures/leaf", word: "x" }

    assert_equal "<i>x</i>", squish(plain.output_buffer)
    assert_equal "<i>alt-x</i>", squish(themed.output_buffer)
  end

  # The overridden path resolved first must not become everyone's answer either.
  def test_respects_view_paths_in_either_order
    themed = view
    themed.lookup_context.prepend_view_paths([alt_view_path])
    themed.instance_eval { bind_render "fixtures/leaf", word: "x" }

    plain = view
    plain.instance_eval { bind_render "fixtures/leaf", word: "x" }

    assert_equal "<i>alt-x</i>", squish(themed.output_buffer)
    assert_equal "<i>x</i>", squish(plain.output_buffer)
  end

  # A relative partial name is resolved against lookup_context.prefixes, which two
  # controllers do not share.
  def test_respects_prefixes_for_a_relative_path
    a = view
    a.lookup_context.prefixes = ["alpha"]
    b = view
    b.lookup_context.prefixes = ["beta"]

    a.instance_eval { bind_render "card" }
    b.instance_eval { bind_render "card" }

    assert_equal "<i>alpha</i>", squish(a.output_buffer)
    assert_equal "<i>beta</i>", squish(b.output_buffer)
  end

  def test_collection_respects_prefixes_for_a_relative_path
    a = view
    a.lookup_context.prefixes = ["alpha"]
    b = view
    b.lookup_context.prefixes = ["beta"]

    a.instance_eval { bind_render_each "card", %w[x], as: :ignored }
    b.instance_eval { bind_render_each "card", %w[x], as: :ignored }

    assert_equal "<i>alpha</i>", squish(a.output_buffer)
    assert_equal "<i>beta</i>", squish(b.output_buffer)
  end

  # Prefixes can change part-way through one view's render.
  def test_notices_a_prefix_change_within_one_view
    v = view
    v.lookup_context.prefixes = ["alpha"]
    v.instance_eval { bind_render "card" }
    v.lookup_context.prefixes = ["beta"]
    v.instance_eval { bind_render "card" }

    assert_equal "<i>alpha</i><i>beta</i>", dense(v.output_buffer)
  end

  def test_matches_render_for_a_relative_path
    bound = view
    bound.lookup_context.prefixes = ["beta"]
    bound.instance_eval { bind_render "card" }

    plain = view
    plain.lookup_context.prefixes = ["beta"]
    assert_equal squish(plain.render("card")), squish(bound.output_buffer)
  end

  # CACHE.clear leaves a warmed view holding the map it memoised; the generation is what
  # makes it rebuild. Ordinary reloads also replace the details key, which hides this.
  def test_clear_cache_invalidates_a_warmed_view
    v = view
    before = ViewBind.bound_for_locals(v, "fixtures/leaf", { word: "x" })

    ViewBind.clear_cache

    after = ViewBind.bound_for_locals(v, "fixtures/leaf", { word: "x" })
    refute_same before, after
    refute_predicate ViewBind::CACHE, :empty?, "the rebuilt binding was not cached again"
  end

  # --- memo keys --------------------------------------------------------------------------

  # A SafeBuffer and an equal String are eql? and hash alike, so an unmarked memo lets the
  # first one rendered decide the escaping for both. Safe-first is the direction that emits
  # attacker-controlled markup raw.
  def test_memo_does_not_share_an_entry_between_safe_and_unsafe_strings
    memoised = view
    memoised.instance_eval { bind_render_memo "fixtures/leaf", word: "<b>u</b>".html_safe }
    memoised.instance_eval { bind_render_memo "fixtures/leaf", word: "<b>u</b>" }

    plain = view
    plain.instance_eval { bind_render "fixtures/leaf", word: "<b>u</b>".html_safe }
    plain.instance_eval { bind_render "fixtures/leaf", word: "<b>u</b>" }

    assert_equal "<i><b>u</b></i><i>&lt;b&gt;u&lt;/b&gt;</i>", dense(memoised.output_buffer)
    assert_equal dense(plain.output_buffer), dense(memoised.output_buffer)
  end

  def test_memo_does_not_share_an_entry_in_the_other_order
    v = view
    v.instance_eval { bind_render_memo "fixtures/leaf", word: "<b>u</b>" }
    v.instance_eval { bind_render_memo "fixtures/leaf", word: "<b>u</b>".html_safe }

    assert_equal "<i>&lt;b&gt;u&lt;/b&gt;</i><i><b>u</b></i>", dense(v.output_buffer)
  end

  # The same collision, one local along in a composite key.
  def test_memo_separates_safe_and_unsafe_strings_among_several_locals
    v = view
    v.instance_eval { bind_render_memo "fixtures/pair", a: "<b>x</b>".html_safe, b: "y" }
    v.instance_eval { bind_render_memo "fixtures/pair", a: "<b>x</b>", b: "y" }

    assert_equal "<i><b>x</b>|y</i><i>&lt;b&gt;x&lt;/b&gt;|y</i>", dense(v.output_buffer)
  end

  # The safety mask lives beside the value rather than inside it, so no local can spell its
  # way into another entry. A marker prefixed onto the value could be forged by input.
  def test_memo_cannot_be_forged_by_a_value_shaped_like_a_safety_marker
    v = view
    v.instance_eval { bind_render_memo "fixtures/leaf", word: "<b>x</b>".html_safe }
    v.instance_eval { bind_render_memo "fixtures/leaf", word: "\u0000html_safe:<b>x</b>" }

    assert_equal "<i><b>x</b></i><i>\u0000html_safe:&lt;b&gt;x&lt;/b&gt;</i>", dense(v.output_buffer)
  end

  # An html_safe local is still worth memoising; marking it must not turn every call into a
  # miss, or the helper stops doing its job for translated markup.
  def test_memo_still_hits_for_a_repeated_safe_string
    v = view
    3.times { v.instance_eval { bind_render_memo "fixtures/side_effect", word: "x".html_safe } }
    assert_equal "x", v.content_for(:counters).to_s
  end

  # A SafeBuffer that has been made unsafe escapes exactly like a String, so sharing is right.
  def test_memo_shares_an_entry_with_an_unsafe_safe_buffer
    buffer = ActiveSupport::SafeBuffer.new("<b>u</b>")
    buffer.sub!("u", "u")
    refute_predicate buffer, :html_safe?

    v = view
    v.instance_eval { bind_render_memo "fixtures/side_effect", word: buffer }
    v.instance_eval { bind_render_memo "fixtures/side_effect", word: "<b>u</b>" }
    assert_equal "x", v.content_for(:counters).to_s, "the unsafe buffer did not share the entry"
  end

  # Hash copies a bare String key; a String inside an Array key it does not. Mutating the
  # string afterwards must not move the stored entry.
  def test_memo_snapshots_string_values_inside_a_composite_key
    word = +"x"
    v = view
    v.instance_eval { bind_render_memo "fixtures/pair", a: word, b: "y" }
    word << "!"

    assert_equal [["x", "y"]], memo_entries(v).keys, "the stored key followed the caller's string"

    v.instance_eval { bind_render_memo "fixtures/pair", a: "x", b: "y" }
    v.instance_eval { bind_render_memo "fixtures/pair", a: "x!", b: "y" }
    assert_equal "<i>x|y</i><i>x|y</i><i>x!|y</i>", dense(v.output_buffer)
  end

  # Hash copies a key whose class is exactly String, but not a SafeBuffer, so the single-value
  # key needs the same snapshot the composite one gets.
  def test_memo_snapshots_a_safe_buffer_used_as_the_whole_key
    word = ActiveSupport::SafeBuffer.new(+"x")
    v = view
    v.instance_eval { bind_render_memo "fixtures/leaf", word: word }
    word << "!"

    assert_equal ["x"], memo_entries(v).keys.map(&:to_s), "the stored key followed the caller's buffer"
    assert_predicate memo_entries(v).keys.first, :frozen?
  end

  # The memo carries the same context defect as the shared cache when it keys on the details
  # key alone.
  def test_memo_respects_view_paths
    plain = view
    plain.instance_eval { bind_render_memo "fixtures/leaf", word: "x" }

    themed = view
    themed.lookup_context.prepend_view_paths([alt_view_path])
    themed.instance_eval { bind_render_memo "fixtures/leaf", word: "x" }

    assert_equal "<i>x</i>", squish(plain.output_buffer)
    assert_equal "<i>alt-x</i>", squish(themed.output_buffer)
  end

  def test_memo_respects_a_prefix_change_within_one_view
    v = view
    v.lookup_context.prefixes = ["alpha"]
    v.instance_eval { bind_render_memo "card" }
    v.lookup_context.prefixes = ["beta"]
    v.instance_eval { bind_render_memo "card" }

    assert_equal "<i>alpha</i><i>beta</i>", dense(v.output_buffer)
  end

  # Numeric keys must not collapse either: 1 and 1.0 are ==, and a Hash key is eql?.
  def test_memo_separates_equal_numbers_of_different_types
    v = view
    v.instance_eval { bind_render_memo "fixtures/leaf", word: 1 }
    v.instance_eval { bind_render_memo "fixtures/leaf", word: 1.0 }
    assert_equal "<i>1</i><i>1.0</i>", dense(v.output_buffer)
  end

  # --- dependency tracking ----------------------------------------------------------------

  # The tracker is a regex over the source, so every documented call form has to be in it.
  # A form it misses leaves the parent's fragment digest unchanged when the child is edited.
  def test_tracker_finds_every_public_helper_form
    forms = {
      %q{<%= bind_render "fixtures/leaf" %>}                      => "bare bind_render",
      %q{<%= bind_render("fixtures/leaf") %>}                     => "parenthesised bind_render",
      %q{<%= bind_capture "fixtures/leaf" %>}                     => "bare bind_capture",
      %q{<%= bind_capture("fixtures/leaf") %>}                    => "parenthesised bind_capture",
      %q{<%= bind_render_memo "fixtures/leaf", word: x %>}        => "bare bind_render_memo",
      %q{<%= bind_render_memo("fixtures/leaf", word: x) %>}       => "parenthesised bind_render_memo",
      %q{<%= bind_render_each "fixtures/leaf", @x, as: :x %>}     => "bare bind_render_each",
      %q{<%= bind_render_each("fixtures/leaf", @x, as: :x) %>}    => "parenthesised bind_render_each"
    }
    forms.each do |source, description|
      assert_includes ViewBind::Tracker.call("t", erb_template(source)), "fixtures/leaf",
                      "#{description} was not tracked"
    end
  end

  def test_tracker_ignores_a_dynamic_path
    assert_empty ViewBind::Tracker.call("t", erb_template(%q{<%= bind_render(path) %>}))
  end

  # A string literal on the line after an argument-less call is not that call's path.
  def test_tracker_does_not_reach_across_a_line_break
    source = %(<% bind_render %>\n<% x = "fixtures/leaf" %>)
    assert_empty ViewBind::Tracker.call("t", erb_template(source))
  end

  # The end-to-end version. fixtures/digest_probe exists only for these two tests: it reaches
  # fixtures/named through bind_render_memo and nothing else, so its digest can only move if
  # that form is tracked.
  def test_dependency_tracking_busts_digests_for_the_memo_form
    assert_digest_changes "fixtures/digest_probe", Rails.root.join("views/fixtures/_named.html.erb")
  end

  # ...and reaches fixtures/digest_leaf only through a parenthesised bind_capture. Both
  # fixtures exist solely for these tests, so the edit-and-restore below cannot leave another
  # test asserting on markup this one changed.
  def test_dependency_tracking_busts_digests_for_a_parenthesised_call
    assert_digest_changes "fixtures/digest_probe", Rails.root.join("views/fixtures/_digest_leaf.html.erb")
  end

  # --- resolution paths not otherwise exercised ---------------------------------------------

  # With template caching off, nothing is cached and every call re-resolves. bind_render_each
  # takes the other entry point into the cache, so it needs its own pass over that branch.
  def test_collection_resolves_every_call_when_template_caching_is_off
    was = ActionView::Resolver.caching?
    ActionView::Resolver.caching = false

    v = view
    v.instance_eval { bind_render_each "fixtures/item", %w[a], as: :item }

    assert_equal "<li>a@0/1!</li>", squish(v.output_buffer)
    assert_predicate ViewBind::CACHE, :empty?, "nothing should be cached with caching off"
  ensure
    ActionView::Resolver.caching = was
  end

  # The second call has to find the binding the first one stored rather than resolving again.
  def test_collection_reuses_a_cached_binding
    v = view
    2.times { v.instance_eval { bind_render_each "fixtures/item", %w[a], as: :item } }

    assert_equal "<li>a@0/1!</li><li>a@0/1!</li>", dense(v.output_buffer)
    entries = ViewBind.bindings_for(v)["fixtures/item"]
    assert_equal 1, entries.size, "the collection binding was resolved twice"
  end

  # A strict-locals partial cannot be called through its compiled method, so the collection
  # loop has a second body that goes through Template#render for the whole collection.
  def test_collection_supports_strict_locals
    bound = view
    bound.instance_eval { bind_render_each "fixtures/strict_item", %w[a b], as: :item }

    assert_equal "<b>a#0</b><b>b#1</b>", dense(bound.output_buffer)
    assert_equal dense(view.render(partial: "fixtures/strict_item", collection: %w[a b], as: :item)),
                 dense(bound.output_buffer)
  end

  # Past the cap the partial still renders correctly, it just stops being remembered.
  def test_memo_stops_storing_past_the_cap
    limit = ViewBind::Helper::MEMO_LIMIT_PER_SHAPE
    v = view
    (limit + 1).times { |n| v.instance_eval { bind_render_memo "fixtures/leaf", word: "w#{n}" } }

    assert_equal limit, memo_entries(v).size, "the cap did not hold"
    assert_includes v.output_buffer.to_s, "<i>w#{limit}</i>", "the over-cap value did not render"
  end

  def test_profiler_summary_reports_how_many_partials_it_left_out
    ViewBind.profile = true
    ViewBind::Profiler.reset
    v = view
    v.instance_eval { bind_render "fixtures/leaf", word: "x" }
    v.instance_eval { bind_render "fixtures/greeting" }

    assert_match(/… and 1 more partial$/, ViewBind::Profiler.summary(limit: 1))

    v.instance_eval { bind_render "fixtures/named", primary: "p" }
    assert_match(/… and 2 more partials$/, ViewBind::Profiler.summary(limit: 1))
  ensure
    ViewBind.profile = false
    ViewBind::Profiler.reset
  end

  # --- the railtie's per-request summary ----------------------------------------------------

  def test_profiling_logs_one_summary_per_request
    log = capture_rails_log do
      ViewBind.profile = true
      get "/page"
    end

    assert_match(/ViewBind: \d+ calls/, log)
    assert_match(%r{fixtures/leaf}, log)
  end

  # Profiling on, but the action rendered no bound partial: there is nothing to say, and the
  # railtie must not log an empty summary line.
  def test_profiling_logs_nothing_for_a_request_without_bound_partials
    log = capture_rails_log do
      ViewBind.profile = true
      assert_equal "<p>plain</p>", squish(get("/plain").response.body)
    end

    refute_match(/ViewBind:/, log)
  end

  # --- tracker registration edge cases ------------------------------------------------------

  def test_tracker_default_follows_the_ruby_render_tracker
    # ActionView.render_tracker arrived in Rails 8.1 -- 7.1 and 8.0 ship only the regex
    # tracker -- which is why default_tracker asks respond_to? before reading it.
    skip "ActionView.render_tracker is Rails 8.1+" unless ActionView.respond_to?(:render_tracker)

    # The restore lives inside a begin rather than on the method: a method-level ensure runs
    # for the skip above too, and would bury it under a NoMethodError from the writer.
    was = ActionView.render_tracker
    begin
      ActionView.render_tracker = :ruby
      assert_equal ActionView::DependencyTracker::RubyTracker, ViewBind::Tracker.default_tracker
    ensure
      ActionView.render_tracker = was
    end
  end

  # DependencyTracker exposes no reader for a handler's tracker, so ours reaches for the
  # registry directly. Every way that reach can come back empty has to end in nil, not raise.
  def test_existing_tracker_is_nil_when_the_registry_cannot_be_indexed
    swap_tracker_registry(Object.new) do
      assert_nil ViewBind::Tracker.send(:existing_tracker_for, erb_handler)
    end
  end

  def test_existing_tracker_is_nil_when_the_registry_already_holds_us
    swap_tracker_registry({ erb_handler => ViewBind::Tracker }) do
      assert_nil ViewBind::Tracker.send(:existing_tracker_for, erb_handler)
    end
  end

  def test_existing_tracker_is_nil_when_the_registry_raises
    registry = Object.new
    registry.define_singleton_method(:[]) { |_handler| raise "registry unavailable" }

    swap_tracker_registry(registry) do
      assert_nil ViewBind::Tracker.send(:existing_tracker_for, erb_handler)
    end
  end

  # A path with no slash is resolved against the template's own directory at render time, so
  # the dependency has to name it the same way or the digestor cannot find the partial.
  def test_tracker_resolves_a_relative_path_against_the_template_directory
    source = %q{<%= bind_render "card" %>}
    assert_equal ["audit/card"], ViewBind::Tracker.call("audit/bound", erb_template(source))
    assert_equal ViewBind::Tracker.call("audit/plain", erb_template(%q{<%= render "card" %>})),
                 ViewBind::Tracker.call("audit/plain", erb_template(source))
  end

  # A template with no directory component of its own. Rails' tracker produces a leading
  # slash here; matching it is what keeps the two digests agreeing.
  def test_tracker_matches_rails_for_a_relative_path_in_a_top_level_template
    assert_equal ViewBind::Tracker.call("page", erb_template(%q{<%= render "card" %>})),
                 ViewBind::Tracker.call("page", erb_template(%q{<%= bind_render "card" %>}))
  end

  # ...and the digest has to move when that partial is edited. audit/bound reaches audit/card
  # only by the relative name.
  def test_dependency_tracking_busts_digests_for_a_relative_path
    assert_digest_changes "audit/bound", Rails.root.join("views/audit/_card.html.erb")
  end

  # prefixes is a public accessor and Rails resolves against a nil list perfectly well, so
  # snapshotting it must not be where that stops working.
  def test_tolerates_nil_prefixes
    bound = view
    bound.lookup_context.prefixes = nil
    bound.instance_eval { bind_render "fixtures/leaf", word: "x" }

    plain = view
    plain.lookup_context.prefixes = nil
    assert_equal squish(plain.render("fixtures/leaf", word: "x")), squish(bound.output_buffer)
    assert_equal "<i>x</i>", squish(bound.output_buffer)
  end

  # A prefix string edited in place rather than replaced: a shallow copy of the array shares
  # the string, so the snapshot moves with the original and the change goes unnoticed.
  def test_notices_a_prefix_mutated_in_place
    prefix = +"alpha"
    v = view
    v.lookup_context.prefixes = [prefix]
    v.instance_eval { bind_render "card" }
    prefix.replace("beta")
    v.instance_eval { bind_render "card" }

    assert_equal "<i>alpha</i><i>beta</i>", dense(v.output_buffer)
  end

  # A strict-locals collection renders through Template#render, which is still a bound render
  # and still has to appear in the summary.
  def test_profiler_measures_a_strict_locals_collection
    ViewBind.profile = true
    ViewBind::Profiler.reset
    v = view
    v.instance_eval { bind_render_each "fixtures/strict_item", %w[a b], as: :item }

    summary = ViewBind::Profiler.summary
    assert_match(/ViewBind: 2 calls/, summary)
    assert_match(%r{fixtures/strict_item\s+x2}, summary)
  ensure
    ViewBind.profile = false
    ViewBind::Profiler.reset
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
    session = get "/page"
    assert_equal 200, session.response.status
    assert_equal "<html><body><span>hello</span><main><p><i>deep</i></p></main></body></html>",
                 dense(session.response.body)
  end

  # Editing a bound partial must change the digest of every template that binds it,
  # otherwise `cache` blocks upstream serve stale HTML.
  def test_dependency_tracking_busts_fragment_digests
    assert_digest_changes "fixtures/page", Rails.root.join("views/fixtures/_leaf.html.erb")
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
  # The child measures itself when COVERAGE is on: the railtie require is the one branch that
  # can only be taken by a process where Rails::Railtie is undefined, and SimpleCov merges the
  # child's result into the suite's by command name.
  def test_loads_without_rails
    lib = File.expand_path("../lib", __dir__)
    # Single-quoted: every line is source for the child, not for this process.
    program = <<~'RUBY'
      if ENV["COVERAGE"]
        require "simplecov"
        SimpleCov.command_name "no-rails"
        # Store the result for the parent to merge, but write no report: the parent owns
        # coverage/ and warns when a second process overwrites what it just produced.
        SimpleCov.formatter = Class.new { def format(_result) = nil }
        SimpleCov.start { enable_coverage :branch }
      end
      raise "Rails was already loaded" if defined?(Rails::Railtie)

      require "view_bind"
    RUBY

    # The child can fail for reasons other than the one under test -- it also loads SimpleCov
    # and asserts Rails is absent -- so its stderr is what the failure message has to carry.
    output, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", program)
    assert status.success?, "the no-Rails child process failed:\n#{output}"
  end

  # --- ported from the pre-audit branch -------------------------------------------------
  #
  # Coverage the current suite did not reach: collection argument handling, fragment
  # caching, non-HTML formats, relative translation keys and render-option rejection.

  # A raised guard must not poison the shape cache: the corrected call site works.
  def test_a_rejected_call_does_not_poison_the_cache
    v = view
    assert_raises(ArgumentError) { v.instance_eval { bind_render "fixtures/leaf", locals: { word: "x" } } }
    v.instance_eval { bind_render "fixtures/leaf", word: "ok" }
    assert_equal "<i>ok</i>", squish(v.output_buffer)
  end

  def test_bind_capture_with_parens_and_locals
    v = view
    assert_equal "<i>cap</i>", squish(v.instance_eval { bind_capture("fixtures/leaf", word: "cap") })
  end

  # Variants resolve through details_key on the plain path too, not only through the memo.
  def test_bind_render_respects_a_variant
    v = view
    v.lookup_context.variants = [:phone]
    v.instance_eval { bind_render "fixtures/variantish", word: "v" }
    assert_equal "<i>phone-v</i>", squish(v.output_buffer)
  end

  # A Hash is an Enumerable with to_a; item locals become [key, value] pairs, same as render.
  def test_collection_accepts_a_hash
    a = view.tap { |v| v.instance_eval { bind_render_each "fixtures/leaf", { k: 1 }, as: :word } }
    b = view.render(partial: "fixtures/leaf", collection: { k: 1 }.to_a, as: :word)
    assert_equal squish(b), squish(a.output_buffer)
  end

  # `render collection: @posts` takes anything with to_a; a mechanically converted call site
  # hands over a relation, not an Array.
  def test_collection_accepts_an_enumerable_that_is_not_an_array
    relation = Class.new do
      def initialize(items) = @items = items
      def to_a = @items
    end.new(%w[r s])

    v = view
    v.instance_eval { bind_render_each "fixtures/item", relation, as: :item }
    assert_equal squish(view.render(partial: "fixtures/item", collection: %w[r s], as: :item)),
                 squish(v.output_buffer)
  end

  def test_collection_accepts_as_given_as_a_string
    v = view
    v.instance_eval { bind_render_each "fixtures/item", %w[a], as: "item" }
    assert_equal "<li>a@0/1!</li>", squish(v.output_buffer)
  end

  def test_collection_passes_shared_locals_to_every_item
    v = view
    v.instance_eval { bind_render_each "fixtures/leaf", [1, 2], as: :item, word: "k" }
    assert_equal "<i>k</i> <i>k</i>", squish(v.output_buffer)
  end

  # as: :object would land in the reserved-keys check with a confusing message; it must be
  # rejected up front like any other invalid name.
  def test_collection_rejects_a_reserved_as_name
    v = view
    assert_raises(ArgumentError) do
      v.instance_eval { bind_render_each "fixtures/item", %w[a], as: :object }
    end
  end

  # `as:` is interpolated into local variable names, so a non-identifier must fail loudly
  # rather than compile garbage.
  def test_collection_rejects_an_invalid_as_name
    v = view
    assert_raises(ArgumentError) do
      v.instance_eval { bind_render_each "fixtures/item", %w[a], as: :"item-1" }
    end
  end

  def test_collection_renders_an_empty_array_as_nothing
    v = view
    v.instance_eval { bind_render_each "fixtures/item", [], as: :item }
    assert_equal "", squish(v.output_buffer)
  end

  # A collection may legitimately contain nil items; the local is just nil then, same as render.
  def test_collection_renders_nil_items
    a = view.tap { |v| v.instance_eval { bind_render_each "fixtures/leaf", [nil], as: :word } }
    b = view.render(partial: "fixtures/leaf", collection: [nil], as: :word)
    assert_equal squish(b), squish(a.output_buffer)
  end

  # The slow path must still provide <as>_counter to a strict partial that declares it.
  def test_collection_slow_path_provides_the_counter
    a = view.tap { |v| v.instance_eval { bind_render_each "fixtures/strict_item", %w[p q], as: :item } }
    b = view.render(partial: "fixtures/strict_item", collection: %w[p q], as: :item)
    assert_equal "<b>p#0</b> <b>q#1</b>", squish(a.output_buffer)
    assert_equal squish(b), squish(a.output_buffer)
  end

  # `render collection: nil` renders nothing; a mechanically converted `render @posts` where
  # the scope can be nil must not raise.
  def test_collection_treats_nil_as_empty
    v = view
    v.instance_eval { bind_render_each "fixtures/item", nil, as: :item }
    assert_equal "", squish(v.output_buffer)
  end

  def test_collection_with_a_missing_partial_raises_missing_template
    v = view
    assert_raises(ActionView::MissingTemplate) do
      v.instance_eval { bind_render_each "fixtures/nope", %w[a], as: :item }
    end
  end

  # Strict-locals partials take the slow path through Template#render; output must still be
  # identical to `render collection:`.
  def test_collection_with_strict_locals_matches_render_collection
    a = view.tap { |v| v.instance_eval { bind_render_each "fixtures/strict", %w[p q], as: :name } }
    b = view.render(partial: "fixtures/strict", collection: %w[p q], as: :name)
    assert_equal squish(b), squish(a.output_buffer)
  end

  # First render of one partial from many threads at once: compute is atomic, compile! holds
  # its own lock, and every thread must come out with correct markup.
  def test_concurrent_first_render_of_one_partial
    ViewBind.clear_cache
    outputs = Array.new(8)
    8.times.map do |i|
      Thread.new do
        v = view
        v.instance_eval { bind_render "fixtures/leaf", word: "t" }
        outputs[i] = squish(v.output_buffer)
      end
    end.each(&:join)
    assert_equal ["<i>t</i>"] * 8, outputs
  end

  # The memo form must participate in digests end to end, not just in the regex: editing the
  # memoised partial has to change the digest of the template that memoises it.
  def test_dependency_tracking_busts_digests_through_bind_render_memo
    leaf = Rails.root.join("views/fixtures/_leaf.html.erb")
    original = File.read(leaf)
    digest = lambda do
      ActionView::Digestor.digest(name: "fixtures/memo_page", format: :html,
                                  finder: view.lookup_context)
    end

    before = digest.call
    File.write(leaf, "#{original}<!-- changed -->")
    ActionView::LookupContext::DetailsKey.clear
    refute_equal before, digest.call
  ensure
    File.write(leaf, original)
    ActionView::LookupContext::DetailsKey.clear
  end

  # `cache` digests through @current_template, which the fast path swaps in itself. The
  # fragment must be written on the first render and served on the second.
  def test_fragment_cache_works_inside_a_bound_partial
    store_was = ActionController::Base.cache_store
    ActionController::Base.cache_store = ActiveSupport::Cache::MemoryStore.new

    first = view
    first.controller.perform_caching = true
    first.instance_eval { bind_render "fixtures/cached", word: "one" }
    assert_equal "<s>one</s>", squish(first.output_buffer)

    second = view
    second.controller.perform_caching = true
    second.instance_eval { bind_render "fixtures/cached", word: "two" }
    assert_equal "<s>one</s>", squish(second.output_buffer), "second render must hit the fragment"
  ensure
    ActionController::Base.cache_store = store_was
  end

  # `locals: { ... }` is render's API; here it would silently become one local named
  # `locals` and produce wrong HTML at every mechanically converted call site.
  def test_locals_option_raises_instead_of_becoming_a_local
    v = view
    assert_raises(ArgumentError) { v.instance_eval { bind_render "fixtures/leaf", locals: { word: "x" } } }
    assert_raises(ArgumentError) { v.instance_eval { bind_render_memo "fixtures/leaf", locals: { word: "x" } } }
    assert_raises(ArgumentError) do
      v.instance_eval { bind_render_each "fixtures/item", %w[a], as: :item, locals: { word: "x" } }
    end
  end

  # The guard is keyed on the key alone: a nil or non-Hash value must not slip past.
  def test_locals_option_raises_regardless_of_value_type
    v = view
    assert_raises(ArgumentError) { v.instance_eval { bind_render "fixtures/leaf", locals: nil } }
    assert_raises(ArgumentError) { v.instance_eval { bind_render "fixtures/leaf", locals: "word" } }
  end

  # The cap bounds memory on a page fed unbounded distinct values; rendering must stay
  # correct past it, only the memoisation stops.
  def test_memo_caps_entries_per_shape
    v = view
    over = ViewBind::Helper::MEMO_LIMIT_PER_SHAPE + 1
    over.times { |i| v.instance_eval { bind_render_memo "fixtures/leaf", word: "w#{i}" } }
    entries = memo_bucket(v, "fixtures/leaf", [:word])
    assert_equal ViewBind::Helper::MEMO_LIMIT_PER_SHAPE, entries.size
    assert_includes v.output_buffer.to_s, "<i>w#{over - 1}</i>"
  end

  # Memo keys must not conflate values that only compare equal across types.
  def test_memo_distinguishes_value_types
    v = view
    v.instance_eval { bind_render_memo "fixtures/leaf", word: 1 }
    v.instance_eval { bind_render_memo "fixtures/leaf", word: "1" }
    entries = memo_bucket(v, "fixtures/leaf", [:word])
    assert_equal 2, entries.size
  end

  # Locale is part of details_key, so a mid-request locale switch must re-render, not serve
  # the first locale's markup.
  def test_memo_respects_a_locale_change
    v = view
    v.instance_eval { bind_render_memo "fixtures/greeting" }
    v.lookup_context.locale = :fr
    v.instance_eval { bind_render_memo "fixtures/greeting" }
    assert_equal "<span>hello</span> <span>bonjour</span>", squish(v.output_buffer)
  end

  def test_memo_with_no_locals_matches_plain_rendering
    memoised = view
    plain    = view
    2.times do
      memoised.instance_eval { bind_render_memo "fixtures/greeting" }
      plain.instance_eval { bind_render "fixtures/greeting" }
    end
    assert_equal squish(plain.output_buffer), squish(memoised.output_buffer)
  end

  # A collection render nested inside a bound partial exercises both state swaps at once.
  def test_nested_collection_inside_a_bound_partial
    v = view
    v.instance_eval { bind_render "fixtures/list", words: %w[a b] }
    assert_equal "<u><i>a</i> <i>b</i> </u>", squish(v.output_buffer)
    assert_nil v.instance_variable_get(:@current_template)
  end

  # The slow (strict-locals) branch of bind_render_each must show up in the profiler like
  # the fast branch does -- those are exactly the collections worth seeing.
  def test_profiler_counts_strict_locals_collections
    ViewBind.profile = true
    ViewBind::Profiler.reset
    v = view
    v.instance_eval { bind_render_each "fixtures/strict", %w[a b c], as: :name }
    assert_match(/fixtures\/strict\s+x3/, ViewBind::Profiler.summary)
  ensure
    ViewBind.profile = false
    ViewBind::Profiler.reset
  end

  # t(".key") derives its scope from @virtual_path, which the fast path swaps in itself; a
  # wrong or stale virtual path resolves the wrong translation.
  def test_relative_translation_key_resolves_inside_a_bound_partial
    I18n.backend.store_translations(:en, fixtures: { translated: { hello: "hi-there" } })
    v = view
    v.instance_eval { bind_render "fixtures/translated" }
    assert_equal "<em>hi-there</em>", squish(v.output_buffer)
  end

  # clear_cache mid-request (the reloader path) must rebuild transparently.
  def test_renders_across_a_cache_clear
    v = view
    v.instance_eval { bind_render "fixtures/leaf", word: "before" }
    ViewBind.clear_cache
    v.instance_eval { bind_render "fixtures/leaf", word: "after" }
    assert_equal "<i>before</i> <i>after</i>", squish(v.output_buffer)
  end

  # Every reserved render option, not just locals:, must fail loudly -- collection: was
  # the silent killer: it would render the partial once with a local named `collection`.
  def test_reserved_render_options_raise_as_locals
    v = view
    assert_raises(ArgumentError) { v.instance_eval { bind_render "fixtures/leaf", collection: %w[a] } }
    assert_raises(ArgumentError) { v.instance_eval { bind_render "fixtures/leaf", object: "x" } }
    assert_raises(ArgumentError) { v.instance_eval { bind_render "fixtures/leaf", partial: "y" } }
  end

  # One entry per locals shape: repeat renders reuse it, a new shape adds one.
  def test_resolution_is_cached_per_locals_shape
    ViewBind.clear_cache
    v = view
    entries = -> { ViewBind.bindings_for(v)["fixtures/leaf"] }
    2.times { v.instance_eval { bind_render "fixtures/leaf", word: "a" } }
    assert_equal 1, entries.call.size

    v.instance_eval { bind_render "fixtures/leaf", word: "b", extra: 1 }
    assert_equal 2, entries.call.size
  end

  # Format is part of details_key: a json lookup must resolve the .json.erb template.
  def test_resolves_a_json_format_partial
    v = view
    v.lookup_context.formats = [:json]
    v.instance_eval { bind_render "fixtures/payload", word: "j" }
    assert_equal '{"word":"j"}', v.output_buffer.to_s.strip
  end

  # Every helper and both call syntaxes must be tracked: a form the regex misses is a partial
  # whose edits never bust upstream cache keys.
  def test_tracker_directive_matches_every_call_form
    src = <<~ERB
      <%= bind_render "a/one" %>
      <%= bind_render("a/two", word: "x") %>
      <%= bind_render_memo "a/three", word: "x" %>
      <%= bind_render_memo("a/four", word: "x") %>
      <%= bind_render_each("a/five", items, as: :item) %>
      <%= bind_capture("a/six") %>
    ERB
    assert_equal %w[a/one a/two a/three a/four a/five a/six],
                 src.scan(ViewBind::Tracker::DIRECTIVE).flatten
  end

  # A dynamic path cannot be tracked; the regex must not invent a dependency from it.
  def test_tracker_ignores_dynamic_paths
    assert_empty '<%= bind_render partial_name, word: "x" %>'.scan(ViewBind::Tracker::DIRECTIVE)
  end

  # An interpolated path cannot be tracked; capturing it as a literal would make Digestor
  # log a missing template on every digest. It must yield no dependency at all.
  def test_tracker_ignores_interpolated_paths
    assert_empty '<%= bind_render "posts/#{kind}_card" %>'.scan(ViewBind::Tracker::DIRECTIVE)
  end

  private

  def alt_view_path = Rails.root.join("alt_views").to_s

  # The railtie logs through Rails.logger; the app's own logger writes to IO::NULL at :fatal.
  def capture_rails_log
    io = StringIO.new
    was = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = was
    ViewBind.profile = false
    ViewBind::Profiler.reset
  end

  # Drives a real request through the app and returns the session, so the response is
  # available to the caller.
  def get(path)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host = "localhost"
    session.get path
    session
  end

  def erb_template(source)
    Struct.new(:source, :handler, :virtual_path).new(source, erb_handler, "t")
  end

  # Digests `name`, edits `file`, and returns having asserted the digest moved.
  def assert_digest_changes(name, file)
    # Read before the begin: an ensure that fires on a failed read would write nil over the
    # fixture and empty it.
    original = File.read(file)
    digest = -> { ActionView::Digestor.digest(name: name, format: :html, finder: view.lookup_context) }

    begin
      before = digest.call
      File.write(file, "#{original}<!-- changed -->")
      ActionView::LookupContext::DetailsKey.clear
      refute_equal before, digest.call, "editing #{file.basename} did not move #{name}'s digest"
    ensure
      File.write(file, original)
      ActionView::LookupContext::DetailsKey.clear
    end
  end
end
