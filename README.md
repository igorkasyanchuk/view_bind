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

Both helpers return `nil` and write into the buffer, so `<%= %>` appends nothing extra.

## Benchmark

A dummy app with a realistic tree — layout → header → nav → nav\_item, a 200-item card
collection whose cards render an author block, a tag collection and three buttons, plus a
sidebar with widgets and a footer. Four routes, **byte-identical HTML**, different call styles.

```
$ RAILS_ENV=production bundle exec rake bench

view_bind 0.1.0 — 200 posts, Rails 8.1.3.1, Ruby 3.4.5 +YJIT
7 rounds x 20 full requests, interleaved, best round per case

                                         ms    gc ms      objects    renders    vs base
  render everywhere (baseline)        9.166     0.95       61 527       2230      1.00x
  bind_render in the view             2.650     0.30       17 500         30      3.52x
  bind_render in the layout           9.073     1.00       60 931       2201      1.01x
  bind_render in both                 2.607     0.25       16 897          1      3.64x
```

Read the object counts: they are exact and do not move with machine load, while milliseconds
swing with whatever else the machine is doing.

**The layout is not where your time goes.** Converting only the layout — header, nav, flashes,
sidebar, footer, about 29 render calls — is worth 1.01x. Converting the view, where a partial
is called once per row, is worth 3.5x. Convert loops, not chrome.

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
| Missing partial still raises `MissingTemplate` | `test_missing_partial_raises_missing_template` |

In development, templates are re-resolved on every call (guarded on
`ActionView::Resolver.caching?`), so editing a partial works without a restart.

## Limitations

- No `:layout`, `:spacer_template`, `:cached` or `:object` options. Use `render` where you need
  them — the two can be mixed freely in the same template.
- The dependency tracker finds `bind_render "some/partial"` by literal string. A path built at
  runtime is invisible to it, so a `cache` block above a dynamically bound partial can go stale.
  Same caveat as Rails' own tracker with dynamic `render`.
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

## Development

```bash
bin/setup
bundle exec rake test    # 11 tests
bundle exec rake bench   # the table above
```

## License

MIT.
