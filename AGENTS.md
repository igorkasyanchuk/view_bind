# AGENTS.md

`view_bind` — render a Rails partial by calling the method ActionView already compiled for it,
instead of walking the `render` path per call. `README.md` explains the gem; this file covers
what an agent working in the repo needs to not get things wrong.

## Commands

```bash
bundle exec rake test      # 112 tests
bundle exec rake coverage  # the same suite under SimpleCov, gated at 100% line and branch
bundle exec rake smoke     # boots the dummy app and checks its logging configuration
bundle exec rake bench     # benchmark suite, see below
bundle exec rake dummy     # dummy app on http://localhost:9292
```

CI runs the suite against Rails 7.1, 8.0 and 8.1 (`gemfiles/`), plus a coverage job. The gem
calls ActionView internals, so a change that passes on one version can fail on another.

## Benchmarking

Two records, different jobs. [`benchmarks/results/README.md`](results/README.md) is the
current snapshot with raw JSON per run — quote from it. [`benchmarks/RESULTS.md`](RESULTS.md)
is the append-only session log, kept so a later run can be compared against an earlier one;
add a dated section there after a fresh measurement rather than rewriting old ones. Read
whichever you are about to quote before quoting it.

```bash
R=5 bundle exec rake bench                  # SQLite (default)
DB=postgres R=5 bundle exec rake bench      # needs: createdb view_bind_bench
APM=1 R=5 bundle exec rake bench            # counters attached while timing
```

Knobs: `R` rounds (9), `N` requests per round (20), `WARMUP` per case (15), `PER` posts per
page (200, 1..500), `SEED` for the case order, `OUTPUT` to write raw JSON, plus `DB` and `APM`.

Run each command **five times and take the median per case** — one run is noise on a loaded
machine. The harness reports the median batch average within a run and randomizes case order
from `SEED`; that is not the same thing as a median across sessions.

### Rules for reporting a benchmark number

1. **Read the OBJECTS column, not milliseconds.** Object counts are exact and stable within a
   session; ms swing 10-30% with machine load. Quote both together — "3.21x fewer objects,
   ~2.6x faster" — never a bare speedup number.
2. **Include the header line** the harness prints (env, eager_load, cache_template_loading,
   whether counters were attached while timing). A result without it is unreadable: in
   development the lookup cache is bypassed and the same code reads ~1.4x, not ~3.2x.
3. **If the harness aborts, do not report.** It asserts every route renders byte-identical HTML
   and aborts otherwise. An abort means the comparison measured nothing — fix the views.
4. **Report the layout row separately.** `bind_render in the layout` is ~1.0x by design: the
   layout is ~61 partials, the page loop is ~2 600. The win is the loop, not the chrome.
   Never average it into a headline.
5. **State which backend a number came from.** Postgres is ~7 ms slower on every route alike,
   which compresses the wall-clock ratio (~1.6x vs ~2.6x) while leaving the allocation ratio
   alone. The allocation ratio is the portable figure.
6. **Warm both paths a few thousand times before quoting any micro-benchmark of a single
   call.** Whichever case is measured first otherwise pays JIT warm-up and reads ~2x slow.
   Does not apply to `rake bench` itself — it warms all routes and interleaves cases.
7. **Do not claim object counts are invariant across processes.** They are stable inside a
   batch of runs; measured drift between sessions is recorded in `benchmarks/RESULTS.md`.

`README.md` also carries an ApacheBench section measured through Puma rather than in-process.
Those are concurrent-throughput numbers and are not comparable with the tables above.

## Layout

- `lib/view_bind/` — the gem. `helper.rb` is the `bind_render` / `bind_capture` /
  `bind_render_memo` / `bind_render_each` surface, `view_bind.rb` the resolution cache,
  `tracker.rb` the fragment-digest dependency tracker, `profiler.rb` the per-request summary.
- `benchmarks/app.rb` — single-file Rails app: 5 routes, 2 000 posts / 6 000 comments,
  42 ERB templates under `benchmarks/views/`. `benchmarks/run.rb` drives it, `bin/rails`
  serves it (`RAILS_ENV=production LOG_LEVEL=info bin/rails s`).
- `docs/` is gitignored — explanations ship as artifacts, not in the repo. Don't add files there
  expecting them to be committed.
