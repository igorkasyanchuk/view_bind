# Changelog

## [0.1.0] - unreleased

- `bind_render` and `bind_render_each`: render a partial through its own compiled method.
- Dependency tracker so `cache` digests still bust when a bound partial changes.
- Lookup cache keyed by the whole resolver context — `details_key`, view paths and prefixes —
  so locales, variants, themed or engine view paths and relative partial names all resolve
  correctly, and `ViewBind.clear_cache` invalidates views that already warmed.
- `bind_render_memo` keys on HTML safety as well as value, so an `html_safe` local and an
  equal escaped one never share an entry.
- Dependency tracking covers every helper form, with or without parentheses.
- `rake coverage`: the suite under SimpleCov, gated at 100% line and branch coverage.
- Templates re-resolved in development, cached in production.
