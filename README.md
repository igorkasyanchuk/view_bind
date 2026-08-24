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
method, writing straight into the current buffer. On a page with a few hundred partial calls
that is most of the render time.

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

view_bind 0.1.0 — 200 posts, Rails 8.1.3.1, Ruby 3.4.5 +YJIT
env=production  eager_load=true  cache_template_loading=true  reloading=false
7 rounds x 20 full requests, interleaved, best round per case

                                         ms    gc ms      objects   renders  queries   vs base
  render everywhere (baseline)       15.082     1.55       81 647      2648        8     1.00x
  bind_render in the view             5.990     0.45       28 020        48        8     2.91x
  bind_render in the layout          15.046     1.40       80 738      2601        8     1.01x
  bind_render in both                 6.047     0.55       27 105         1        8     3.01x

Five consecutive runs moved the millisecond column between 14.1 and 19.3 for the baseline, and
never moved a single object count or ratio.
```

Read the object counts: they are exact and do not move with machine load, while milliseconds
swing with whatever else the machine is doing.

### Measure in production, not in development

The same benchmark under `RAILS_ENV=development`:

```
env=development  eager_load=false  cache_template_loading=false  reloading=true

  render everywhere (baseline)       15.164     1.85       74 689       2630      1.00x
  bind_render in the view             5.502     0.85       41 072         30      1.82x
  bind_render in both                 6.028     0.90       40 690          1      1.84x
```

Half the win. In development the lookup cache is bypassed so that
editing a partial takes effect without a restart, which means every call re-resolves the
template — 41 072 objects instead of 20 900. That is the correct trade, but do not judge the
gem by what you see while clicking around `rails s`.

**The layout is not where your time goes.** Converting only the layout is worth 1.01x.
Converting the view, where a partial is called once per row, is worth 2.9x. Convert loops,
not chrome.

**And the database sets the ceiling.** Those 8 queries and the ActiveRecord objects behind them
cost the same on every route, which is why adding them moved the win from 3.6x to 3.0x. On a
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
