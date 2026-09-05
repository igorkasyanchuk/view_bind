# Changelog

## [0.1.0] - unreleased

- Responsive publication layout for the dummy app, with equivalent output across all routes.
- Reproducible request benchmarks with randomized rounds, median and range reporting,
  response validation, accurate query counts, configurable page size and raw JSON output.
- Concurrent first-render and per-view memo isolation regression coverage.
- Include the changelog and type signature in the built gem.

- `bind_render` and `bind_render_each`: render a partial through its own compiled method.
- Dependency tracker so `cache` digests still bust when a bound partial changes.
- Lookup cache keyed by the whole resolver context — `details_key`, view paths and prefixes —
  so locales, variants, themed or engine view paths and relative partial names all resolve
  correctly, and `ViewBind.clear_cache` invalidates views that already warmed.
- `bind_render_memo` keys on HTML safety as well as value, so an `html_safe` local and an
  equal escaped one never share an entry.
- Dependency tracking covers every helper form, with or without parentheses.
- Relative bound paths resolve against the template's directory for digests, so a `cache`
  block above `bind_render "card"` busts when `card` changes.
- Prefix strings are snapshotted, not just the array, so editing one in place is noticed.
- The profiler measures strict-locals collections, and counts a delegated memo call at its
  own nesting level so its time reaches the header total.
- `rake coverage`: the suite under SimpleCov, gated at 100% line and branch coverage.
- CI matrix over Rails 7.1, 8.0 and 8.1.
- Templates re-resolved in development, cached in production.
