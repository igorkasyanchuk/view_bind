# view_bind

Render a Rails partial by calling the method ActionView already compiled for it, instead of
walking the whole `render` path on every call.

```erb
<%# before %>
<%= render partial: "posts/card", collection: @posts, as: :post %>
<%= render "shared/button", label: "Read", style: "primary" %>

<%# after %>
<%= bind_render_each "posts/card", @posts, as: :post %>
<%= bind_render "shared/button", label: "Read", style: "primary" %>
```

Partials stay ordinary partials. Nothing is merged into the parent template, no source is
rewritten, and every file keeps its own identity — so backtraces, `local_assigns`, strict
locals, development reloading and fragment cache digests all keep working.

## Why it is faster

A normal partial render performs template lookup, creates rendering objects and buffers,
and emits ActiveSupport notifications. For a page with many small partials, that work adds up.

`bind_render` caches the resolved template by resolver context and locals shape, then calls
the method Rails compiled for it, writing into the current output buffer.
`bind_render_each` also resolves once and reuses view bookkeeping across the collection.
Strict-locals templates use `Template#render` for Rails' argument validation.

### bind_render_memo

Memoization reuses a partial's markup within one view context:

```erb
<%= bind_render_memo "shared/tag", tag: "ruby" %>
```

Only String, Symbol, Numeric, true, false and nil values are memoized. Other objects fall
through to rendering. Keys include resolver context, locals names, values and HTML safety;
mutable strings are snapshotted so later mutation does not corrupt stored keys.

Use it only when repeating those inputs should produce the same markup. Instance variables,
current-user state, time and side effects are not part of the key. Request state can change
within a render: a shared request alone does not guarantee correctness.
A hit skips all partial side effects, including `content_for`, `provide` and counters.
It behaves the same with template caching enabled or disabled.

Memoization can reduce allocations without improving latency. Measure the subtree you want
to memoize; the lookup itself has a cost.

## Install

```ruby
gem "view_bind"
```

Nothing to configure. The railtie adds the helpers to every view, partial, layout and mailer
view, and registers a dependency tracker so `cache` digests still notice bound partials.

## Usage

Works the same in a view, in a partial, and in a layout:

```erb
<%# app/views/layouts/application.html.erb %>
<body>
  <%= bind_render "shared/header", user: current_user %>
  <main><%= yield %></main>
  <%= bind_render "shared/footer" %>
</body>
```

```erb
<%# app/views/posts/index.html.erb %>
<section class="cards">
  <%= bind_render_each "posts/card", @posts, as: :post %>
</section>
```

`bind_render_each` provides `<as>_counter` and `<as>_iteration` exactly like
`render collection:`, so existing collection partials keep working:

```erb
<%# app/views/posts/_card.html.erb %>
<article class="card <%= "is-first" if post_iteration.first? %>">
  <h3><%= post_counter + 1 %>. <%= post.title %></h3>
</article>
```

Both helpers write into the buffer and return `nil`, so `<%= %>` appends nothing extra. When
you need the markup **as a value** — `content_for`, a helper argument — use `bind_capture`,
which returns a string:

```erb
<% content_for :sidebar, bind_capture("shared/widget") %>
```

Passing `bind_render` itself as a value would put the HTML in the page and store an empty
string, so the block form of `render` is not supported either: passing a block raises
`ArgumentError` rather than dropping it silently.

## Benchmark

The dummy app renders a responsive publication page with a featured article, a card grid,
navigation, tags, author information, buttons, community statistics, ranked posts and comments.
It uses 2,000 posts, 6,000 comments and 10 authors, with **10 SQL queries per request**.

All five routes produce equivalent HTML after normalizing the footer timestamp. The baseline
already uses Rails' collection renderer. The default is 200 cards, which deliberately exercises
many nested partials; use `PER=20` for a smaller page.

```sh
bundle exec rake bench
PER=20 bundle exec rake bench
OUTPUT=tmp/benchmark.json bundle exec rake bench

# Use a dedicated database: the dummy app creates/reseeds its tables.
createdb view_bind_bench
DB=postgres PGUSER=your_user PGDATABASE=view_bind_bench bundle exec rake bench

# Synthetic notification subscribers, not a named production APM agent:
APM=1 bundle exec rake bench
```

The runner defaults to production mode, 15 warmup requests per case and nine rounds of twenty
requests. Case order is randomized using a reproducible seed. Override `WARMUP`, `R`, `N`,
`SEED` or `PER` as needed; `PER` accepts 1–500. `OUTPUT` saves metadata and all raw rounds.
Use `RAILS_ENV=development bundle exec ruby benchmarks/run.rb` for an explicit development run;
`rake bench` always selects production.

Reported times are **median batch averages**; min–max describes batch variation, not request
latency percentiles. Each request must return HTTP 200, and output equivalence is checked
before timing and after every batch. Allocations are averaged per request, not universal constants.

The `observed` column counts template instances reported through Rails notifications, including
collection payload counts. Bound templates still execute even though they emit fewer events.
The default timing excludes the benchmark's inspection subscribers.

See [the current measured results](benchmarks/results/README.md) and accompanying raw JSON.
These are serial in-process measurements, not browser load times or concurrent throughput.
Database latency, page size, GC and instrumentation affect the result; benchmark your own page.
No leaf-level microsecond or profiler-overhead claims are inferred from this request benchmark.

### Concurrent throughput, over HTTP

The numbers above are serial and in-process. This is the same page behind Puma, measured with
ApacheBench, so the socket, the router and the middleware stack are all included:

```sh
RAILS_ENV=production LOG_LEVEL=info bin/rails s -b 127.0.0.1 -p 3000
```

```sh
ab -n 200 -c 2 'http://127.0.0.1:3000/?per=200'
ab -n 200 -c 2 'http://127.0.0.1:3000/bind_both?per=200'
```

| | `/` (standard Rails) | `/bind_both` (view\_bind) |
| --- | ---: | ---: |
| Requests/sec | 79.12 | **181.20** |
| Mean request time | 25.28 ms | **11.04 ms** |
| Median latency | 25 ms | **11 ms** |
| p95 latency | 30 ms | **12 ms** |
| Total for 200 requests | 2.528 s | **1.104 s** |
| Failed requests | 0 | 0 |

**2.29x the throughput (+129%) and 56% lower mean request time**, both routes returning the
same 228 KB of HTML. Medians of three runs of 200 requests at concurrency 2 after warming, on
one Puma worker with five threads over loopback, Ruby 3.4.5 +YJIT and SQLite.

`/bind_memo` measures the same as `/bind_both` here (178.66 req/s, 11.20 ms, inside the
run-to-run spread). Over HTTP the remaining time is dominated by the 10 queries and the request
cycle, so the memo's extra saving only shows up in the in-process table.

`ab` runs on the same machine as the server and competes with it for cores, and a laptop under
load will not reproduce these exact figures. Run it against your own page.

## What it does not change

Each of these is a test in the suite, because each is a way this kind of optimisation usually
goes wrong:

| behaviour | test |
| --- | --- |
| Same HTML as `render` | `test_matches_what_render_produces` |
| Locals, including strict locals | `test_passes_locals`, `test_supports_strict_locals` |
| `_counter` / `_iteration` in collections | `test_collection_provides_counter_and_iteration` |
| Per-locale / per-variant partials | `test_respects_locale` |
| Per-view-path and per-prefix partials | `test_respects_view_paths`, `test_respects_prefixes_for_a_relative_path` |
| Backtraces naming the real file and line | `test_backtrace_points_at_the_partial` |
| Fragment cache digests busting on edits | `test_dependency_tracking_busts_fragment_digests` |
| Works in a layout, and nested | `test_works_in_a_layout_and_nested_partials` |
| Instance variables in nested partials | `test_instance_variables_reach_nested_partials` |
| Missing partial still raises `MissingTemplate` | `test_missing_partial_raises_missing_template` |
| `bind_capture` returns markup, `content_for` works | `test_bind_capture_works_with_content_for` |
| A block raises instead of being dropped | `test_block_form_raises_instead_of_being_ignored` |
| The output-buffer limitation stays as documented | `test_a_partial_that_hijacks_the_output_buffer_renders_nothing` |
| Memo keys on the locals shape, not just values | `test_memo_does_not_collide_on_the_value_alone` |
| Memo behaves the same with caching on and off | `test_memo_behaves_the_same_with_and_without_template_caching` |
| Memo respects a variant or locale change | `test_memo_respects_a_variant_change` |
| Memo never shares an entry between safe and escaped strings | `test_memo_does_not_share_an_entry_between_safe_and_unsafe_strings` |
| Every helper form is tracked for digests | `test_tracker_finds_every_public_helper_form` |
| Relative bound paths bust digests too | `test_dependency_tracking_busts_digests_for_a_relative_path` |
| `clear_cache` invalidates a warmed view | `test_clear_cache_invalidates_a_warmed_view` |
| A prefix edited in place is noticed | `test_notices_a_prefix_mutated_in_place` |
| A nil prefix list still renders | `test_tolerates_nil_prefixes` |
| A memo key cannot be forged by its value | `test_memo_cannot_be_forged_by_a_value_shaped_like_a_safety_marker` |
| A SafeBuffer memo key gets its own copy | `test_memo_snapshots_a_safe_buffer_used_as_the_whole_key` |
| A delegated memo call is timed at its own depth | `test_profiler_counts_a_delegated_memo_call_once` |
| Memoised side effects run once, as documented | `test_memo_runs_side_effects_once` |
| A strict-locals partial in a collection | `test_collection_supports_strict_locals` |
| The railtie's per-request profile line | `test_profiling_logs_one_summary_per_request` |
| The gem loads outside Rails | `test_loads_without_rails` |

`rake coverage` runs the same suite under SimpleCov and fails below 100% line **and**
branch coverage of `lib/`. The one branch a single process cannot reach — the railtie
`require`, which is skipped only where `Rails::Railtie` is undefined — is covered by the
child process in `test_loads_without_rails`, whose result is merged into the suite's.

CI runs the suite against Rails 7.1, 7.2 and 8.0 (`gemfiles/`), and against the newest
release through the default `Gemfile` (8.1 today, unpinned), because the fast path calls
ActionView internals that move between versions. The dependency remains `actionview >= 7.1`.
`ViewBind.fast_path_available?` detects missing methods and selects `Template#render`, but
method existence cannot guarantee compatible signatures or behavior in future Rails releases.
Validate framework upgrades against your application's rendering tests before deploying them.

In development, templates are re-resolved on every call (guarded on
`ActionView::Resolver.caching?`), so editing a partial works without a restart — and Rails'
debug error page is unchanged. A `NoMethodError` inside a bound partial reports:

```
Showing .../views/shared/_button.html.erb where line #3 raised:
undefined method 'nonexistent_method' for an instance of String
```

with the partial's own source extracted around the failing line, exactly as `render` does.
That is not a trick this gem plays: the partial is a normal compiled template, so
`backtrace_locations`, `SourceMapLocation` and ErrorHighlight all resolve it the usual way.

## Seeing where the time goes

Bound partials produce no `render_partial.action_view` events — that is part of what makes them
cheap — so the per-partial log lines go with them. In their place, one summary per request:

```ruby
# config/environments/development.rb
ViewBind.profile = true
```

```
ViewBind: 302 calls, 24.10ms in bound partials
  posts/card_memo                    x20      17.76ms
  shared/sidebar_bound               x1        3.66ms
  posts/author_bound                 x20       3.33ms
  posts/ownership_bound              x20       1.80ms  (19 memo)
  shared/button                      x61       1.70ms
```

Sorted by time, top ten, one line per partial rather than one per render. Per-partial times nest
exactly as Rails' own do — `posts/card_memo` includes everything its children spent — so the
header totals only the outermost calls rather than summing rows that overlap. The measurement
starts before the binding lookup, so it covers what a call actually costs, not just the partial. `(19 memo)` counts the
calls `bind_render_memo` served without rendering — the hit rate, which is the number worth
checking before deciding whether memoisation earns its place.

The store is cleared when an action starts as well as when it ends, so renders from a mailer or
a job on the same thread cannot be attributed to the next request.

Off by default. While off the cost is a single boolean test per call; switched on it adds two
clock reads, about **0.26 µs per call** — fine for development, not something to leave on in
production.

## Limitations

- No `:layout`, `:spacer_template`, `:cached` or `:object` options. Use `render` where you need
  them — the two can be mixed freely in the same template.
- The dependency tracker finds `bind_render "some/partial"` by literal string, in every helper
  form and with or without parentheses, and resolves a relative name against the template's own
  directory the way the renderer does. A path built at runtime is invisible to it, so a `cache`
  block above a dynamically bound partial can go stale. Same caveat as Rails' own tracker with
  dynamic `render`.
- Dependency tracking is registered for ERB only. For another engine, add
  `ViewBind::Tracker.register_for(:haml)` in an initializer. Registration extends whatever
  tracker is already installed for that handler rather than replacing it.
- No `render` instrumentation is emitted for bound partials, by design. Your APM will show
  fewer view events, and Rails' per-partial `Rendered …` log lines disappear for them — 65
  lines become 2 on the benchmark page. The `Completed … (Views: 16.9ms)` total is unaffected.
  See **Seeing where the time goes** below for the replacement.
- A partial that reassigns `@output_buffer` without restoring it loses its output. These
  helpers write into the buffer they are given, whereas `render` builds its own buffer and
  takes whatever the partial returns, so it survives that. `capture` and `with_output_buffer`
  restore the buffer and are unaffected; only code that assigns the ivar and walks away is.
  Inside `bind_render_each` such an item takes the rest of the collection with it.
- The resolved-template cache is not evicted. It is keyed per call site, per resolver context
  (lookup details, view paths and prefixes), so it is bounded in practice — but passing a varying
  set of locals keys to the same partial grows it.

## When not to use it

If a page makes a handful of render calls, this changes nothing measurable. Reach for it when a
partial is called once per row and there are many rows. Before that, check whether you are
loading ActiveRecord objects you only read from (`pluck` is usually a bigger win) or rendering
more rows than anyone will look at.

## The dummy app

`benchmarks/app.rb` is a single-file Rails application with a persistent SQLite database by
default, or PostgreSQL when `DB=postgres`. The templates share presentation copy, inline CSS
and the same database workload across all rendering modes.

```sh
bin/rails s
# Open http://localhost:3000/?per=6 for a short visual preview.

# Production caching, with request and completion logs:
RAILS_ENV=production LOG_LEVEL=info bin/rails s

# The original launcher is also available on port 9292:
bundle exec rake dummy
```

Development writes normal Rails request, rendering and SQL logs to the terminal and enables
ViewBind profiling summaries. Production disables profiling and discards logs by default; set
`LOG_LEVEL=info` to write request logs to the terminal. Stop an existing server with Ctrl-C
before restarting on the same port.

Benchmarking is separate: `benchmarks/run.rb` turns profiling off in every environment, so it
never times bound renders through `Profiler.measure` while leaving the baseline's `render`
untouched, and runs stay quiet unless `LOG_LEVEL` is set. `bundle exec rake smoke` checks that
logging configuration without running a benchmark.

| route | layout | view |
| --- | --- | --- |
| `/` | `render` | `render` |
| `/bind_view` | `render` | `bind_render` |
| `/bind_layout` | `bind_render` | `render` |
| `/bind_both` | `bind_render` | `bind_render` |
| `/bind_memo` | `bind_render` | bound cards with a memoized ownership subtree |

This is a rendering fixture, not a complete publication app: post/tag detail routes and
account, sharing and saving actions are placeholders.

## Development

```sh
bin/setup
bundle exec rake test
bundle exec rake coverage
bundle exec rake bench
bundle exec rake dummy
BUNDLE_GEMFILE=gemfiles/rails_7.1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_7.1.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle exec rake test
```

## License

MIT.
