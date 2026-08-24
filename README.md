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

A `render` call costs roughly 12&nbsp;µs and ~28 objects *before* your ERB runs, no matter how
small the partial is: an options hash, a fresh `PartialRenderer`, `extract_details`, a template
lookup keyed by details and locals, an `ActiveSupport::Notifications` event, a per-partial
`OutputBuffer`, and a string copy out of it into the parent buffer.

`bind_render` resolves the template once per call site per process and then calls its compiled
method, writing straight into the current buffer: **1.4 µs and 6 objects per call** on a leaf
partial. Three things keep it there:

- a two-level cache (lookup details, then virtual path) whose hit allocates nothing: the
  cached locals shape is compared against the locals hash in place, so not even `locals.keys`
  is built;
- the map for the current lookup details is memoised on the view, so a request derives it
  once instead of once per partial;
- the compiled method is called directly, with the same `@current_template` / `@output_buffer`
  bookkeeping `ActionView::Base#_run` does — from inside the helper, which is included in the
  view class, so those are plain ivar assignments rather than `instance_variable_set`.

`bind_render_each` goes further: every item renders the same template, so the view bookkeeping
is saved and restored once for the whole collection rather than once per item. On a 20-item
collection that is **1.06 µs and 3.6 objects per item, against 2.77 µs and 11.8 for Rails'
own collection renderer.**

Strict-locals partials go back through `Template#render`, which owns the argument checking —
as does everything, on any Rails whose `Template#compile!`, `#method_name` or
`#handle_render_error` this gem cannot find. A rename in a future Rails costs you the speedup,
not your application.

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

A dummy app backed by SQLite — 2 000 posts, 6 000 comments, 10 authors — rendering a realistic
tree: layout → header → nav → nav\_item, 200 cards per page whose cards render an author block,
a tag collection, an ownership block that reads instance variables, a nested badge and three
buttons, plus a sidebar built from four more queries (top categories, busiest authors, recent
comments, totals) and a footer. **8 SQL queries per request**, the same on every route.
Four routes, **byte-identical HTML**, different call styles.

```
$ RAILS_ENV=production bundle exec rake bench

view_bind 0.1.0 — 200 posts per page, Rails 8.1.3.1, Ruby 3.4.5 +YJIT
database=SQLite
env=production  eager_load=true  cache_template_loading=true  reloading=false
5 rounds x 20 full requests, interleaved, best round per case
counters: attached only for the inspection pass

                                         ms    gc ms      objects   renders  queries     obj x    time x
  render everywhere (baseline)       11.250     1.25       68 342      2662       10     1.00x     1.00x
  bind_render in the view             4.450     0.35       21 723        62       10     3.15x     2.52x
  bind_render in the layout          11.160     1.20       67 316      2601       10     1.02x     1.01x
  bind_render in both                 4.420     0.35       20 689         1       10     3.30x     2.57x
```

Medians of five runs of five rounds. 2 662 render calls collapse to 1, 47 653 fewer objects
per request, and the page comes back in 39% of the time.

### The database decides how much of this you keep

Same code, same 10 queries, same HTML — only the backend changed:

| backend | baseline | bind_render in both | speedup |
| --- | ---: | ---: | ---: |
| SQLite, file | 11.25 ms | 4.42 ms | **2.57x** |
| PostgreSQL 17, localhost | 18.72 ms | 11.86 ms | **1.58x** |

Postgres adds a flat ~7 ms to every route, baseline and bound alike, so the same saved work is
a smaller share of a bigger number. The allocation ratio barely moves (3.03x vs 2.98x), which
is why it is the more portable figure.

### If you run an APM

Anything subscribed to `render_partial.action_view` — Skylight, Datadog, New Relic, Scout —
pays a notification per partial. The baseline fires ~2 662 of them per request; the bound page
fires one. Attaching the counters during timing (`APM=1 bundle exec rake bench`) measures that
world:

| | baseline | bind_render in both | speedup |
| --- | ---: | ---: | ---: |
| plain | 11.68 ms | 4.72 ms | 2.50x |
| with view instrumentation | 14.29 ms | 4.74 ms | **3.02x** |

The instrumented baseline is 2.9 ms and 14 334 objects heavier; the bound page is unchanged.
The gem is worth more in an instrumented app than in a bare one.

### Measure in production, not in development

The same benchmark under `RAILS_ENV=development`:

```
env=development  eager_load=false  cache_template_loading=false  reloading=true

  render everywhere (baseline)       15.452     4.75       68 531      2662     1.00x   1.00x
  bind_render in the view             7.753     1.20       48 921        62     1.40x   1.99x
  bind_render in both                 7.238     1.10       48 469         1     1.41x   2.13x
```

In development the lookup cache is bypassed so that editing a partial takes effect without a
restart, so every call re-resolves the template: 48 469 objects instead of 27 847. The
allocation win drops from 2.45x to 1.41x. Wall-clock happens to look similar here because
development also carries more overhead on the baseline side — judge the gem on production
numbers, not on what you see while clicking around `rails s`.

**The layout is not where your time goes.** Converting only the layout is worth 1.01x.
Converting the view, where a partial is called once per row, is worth ~2.5x. Convert loops,
not chrome.

**And the database sets the ceiling.** Those 8 queries and the ActiveRecord objects behind them
cost the same on every route, which is why adding them moved the win from 3.6x to ~2.5x. On a
page that renders 20 rows instead of 200, or one that spends 40 ms in the database, the number
would be smaller still. Measure your own page before adopting anything here.

## What it does not change

Each of these is a test in the suite, because each is a way this kind of optimisation usually
goes wrong:

| behaviour | test |
| --- | --- |
| Same HTML as `render` | `test_matches_what_render_produces` |
| Locals, including strict locals | `test_passes_locals`, `test_supports_strict_locals` |
| `_counter` / `_iteration` in collections | `test_collection_provides_counter_and_iteration` |
| Per-locale / per-variant partials | `test_respects_locale` |
| Backtraces naming the real file and line | `test_backtrace_points_at_the_partial` |
| Fragment cache digests busting on edits | `test_dependency_tracking_busts_fragment_digests` |
| Works in a layout, and nested | `test_works_in_a_layout_and_nested_partials` |
| Instance variables in nested partials | `test_instance_variables_reach_nested_partials` |
| Missing partial still raises `MissingTemplate` | `test_missing_partial_raises_missing_template` |
| `bind_capture` returns markup, `content_for` works | `test_bind_capture_works_with_content_for` |
| A block raises instead of being dropped | `test_block_form_raises_instead_of_being_ignored` |
| The output-buffer limitation stays as documented | `test_a_partial_that_hijacks_the_output_buffer_renders_nothing` |
| The gem loads outside Rails | `test_loads_without_rails` |

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

## Limitations

- No `:layout`, `:spacer_template`, `:cached` or `:object` options. Use `render` where you need
  them — the two can be mixed freely in the same template.
- The dependency tracker finds `bind_render "some/partial"` by literal string. A path built at
  runtime is invisible to it, so a `cache` block above a dynamically bound partial can go stale.
  Same caveat as Rails' own tracker with dynamic `render`.
- Dependency tracking is registered for ERB only. For another engine, add
  `ViewBind::Tracker.register_for(:haml)` in an initializer. Registration extends whatever
  tracker is already installed for that handler rather than replacing it.
- No `render` instrumentation is emitted for bound partials, by design. Your APM will show
  fewer view events and per-partial timings for them disappear.
- A partial that reassigns `@output_buffer` without restoring it loses its output. These
  helpers write into the buffer they are given, whereas `render` builds its own buffer and
  takes whatever the partial returns, so it survives that. `capture` and `with_output_buffer`
  restore the buffer and are unaffected; only code that assigns the ivar and walks away is.
  Inside `bind_render_each` such an item takes the rest of the collection with it.
- The resolved-template cache is not evicted. It is keyed per call site, per lookup details, so
  it is bounded in practice — but passing a varying set of locals keys to the same partial grows
  it.

## When not to use it

If a page makes a handful of render calls, this changes nothing measurable. Reach for it when a
partial is called once per row and there are many rows. Before that, check whether you are
loading ActiveRecord objects you only read from (`pluck` is usually a bigger win) or rendering
more rows than anyone will look at.

## The dummy app

`benchmarks/app.rb` is a single-file Rails application — four routes, a controller, 200
in-memory posts and 29 ERB templates under `benchmarks/views/`. The benchmark drives it
in-process, and you can also serve it and click through:

```bash
bundle exec rake dummy   # http://localhost:9292
```

| route | layout | view |
| --- | --- | --- |
| `/` | `render` | `render` |
| `/bind_view` | `render` | `bind_render` |
| `/bind_layout` | `bind_render` | `render` |
| `/bind_both` | `bind_render` | `bind_render` |

All four return byte-identical HTML. It ships no CSS on purpose: it exists to be measured,
not to look like anything.

## Development

```bash
bin/setup
bundle exec rake test    # 11 tests
bundle exec rake bench   # the table above
bundle exec rake dummy   # browse the dummy app
```

## License

MIT.
