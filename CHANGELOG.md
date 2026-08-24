# Changelog

## [0.1.0] - unreleased

- `bind_render` and `bind_render_each`: render a partial through its own compiled method.
- Dependency tracker so `cache` digests still bust when a bound partial changes.
- Lookup cache keyed by `details_key`, so locales and variants resolve correctly.
- Templates re-resolved in development, cached in production.
