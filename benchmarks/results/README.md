# Request benchmark results

Measured September 5, 2026 using the redesigned publication fixture and the accompanying
`benchmarks/run.rb`. Runtime: Ruby 3.4.4 + YJIT, Rails 8.1.3.1, arm64 macOS. Databases:
persistent SQLite and PostgreSQL 17 on localhost. Profiling and synthetic APM subscribers
were off during timing. All five rendering modes returned equivalent HTML and executed
10 SQL queries per request.

Each case received 15 warmup requests, then nine randomized rounds of twenty requests
(seed 20260905). Times below are median batch averages, not tail-latency percentiles.

| Database | Posts/page | Rails render | Bound view and layout | Less request time | Fewer allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| SQLite | 20 | 2.066 ms | 1.404 ms | 32.0% | 51.6% |
| SQLite | 200 | 9.195 ms | 3.550 ms | 61.4% | 69.6% |
| PostgreSQL | 20 | 7.752 ms | 6.717 ms | 13.4% | 51.3% |
| PostgreSQL | 200 | 14.822 ms | 9.006 ms | 39.2% | 69.4% |

Memoizing the ownership subtree at 200 posts used 3.580 ms on SQLite and 9.018 ms on
PostgreSQL. It saved allocations but did not establish a latency improvement over the
ordinary bound page in this run.

PostgreSQL's 200-post baseline batches ranged from 14.265 to 15.602 ms; bound batches
ranged from 8.385 to 14.506 ms. The wider variation on some runs is why the raw samples
are retained and minimum timings are not used as the headline result.

## Reproduce

```sh
PER=20 OUTPUT=tmp/sqlite-20.json bundle exec rake bench
PER=200 OUTPUT=tmp/sqlite-200.json bundle exec rake bench

# Create a dedicated disposable benchmark database first.
createdb view_bind_bench
DB=postgres PGUSER=your_user PGDATABASE=view_bind_bench PER=20 OUTPUT=tmp/postgres-20.json bundle exec rake bench
DB=postgres PGUSER=your_user PGDATABASE=view_bind_bench PER=200 OUTPUT=tmp/postgres-200.json bundle exec rake bench
```

Raw metadata and every round: [SQLite, 20 posts](sqlite-20.json),
[SQLite, 200 posts](sqlite-200.json), [PostgreSQL, 20 posts](postgres-20.json),
[PostgreSQL, 200 posts](postgres-200.json).

These are serial in-process request measurements. They include controller/database work
but exclude browser rendering, network transfer and server queueing under concurrent load.
The 200-post page intentionally has many nested partials. Smaller pages or requests dominated
by database/external-service latency should not be expected to reproduce its percentage gain.
Changing the HTML, runtime, database or profiling configuration requires a new measurement.

## Readiness checks for this revision

- Ruby 3.4.4 / Rails 8.1.3.1: 78 tests, 171 assertions, no failures or skips.
- Ruby 3.4.4 / Rails 8.0.5.1: 78 tests, no failures; the Rails-8.1-only tracker test is skipped.
- Ruby 3.1.2 / Rails 7.1.6: 78 tests, no failures; the same version-specific test is skipped.
- Line coverage: 252/252; branch coverage: 85/85.
- The previous ten independent audit regressions pass. The normal suite includes the fixes,
  and a new concurrent first-render test checks locals and per-view memo isolation.
- The gem builds with runtime files, README, changelog, license and type signature.

No remaining blocker was found for the tested Ruby/Rails configurations and documented ERB
usage. This does not certify every application or future Rails version: the gem uses private
ActionView APIs. Memoization requires stable inputs/state, and dynamic resolver contexts or
locals shapes can grow the process cache; see the README limitations before rollout.
