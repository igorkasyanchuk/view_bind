# Benchmark results

Recorded runs of `rake bench`. One section per measurement session. Append, do not rewrite:
the point of the file is that a later run can be compared against an earlier one.

How these were produced, and how to reproduce:

```bash
R=5 bundle exec rake bench                  # SQLite (default)
DB=postgres R=5 bundle exec rake bench      # needs: createdb view_bind_bench
APM=1 R=5 bundle exec rake bench            # counters attached while timing
```

Each command was run **five times** and the **median per case** taken. `R` is rounds per run
(the harness already keeps the best round per case), `N` is requests per round (default 20).
A single run is noise on a busy machine; a single round is noise inside a run.

## Reading the table

- **Read the OBJECTS column, not milliseconds.** Object counts are exact and stable inside a
  session; ms move 10-30% with machine load. Quote allocations and wall-clock together —
  "3.21x fewer objects, ~2.6x faster" — never a bare speedup number.
- **Always keep the header line** (env, eager_load, cache_template_loading, whether counters
  were attached while timing). A number without it is unreadable: development bypasses the
  lookup cache and the same code reads ~1.4x instead of ~3.2x.
- **Always state the backend.** Postgres adds ~7 ms of query time to every route alike, which
  compresses the wall-clock ratio without touching the allocation ratio.
- **The layout row is ~1.0x by design.** The layout is ~61 partials; the page loop is ~2 600.
  The win is the loop, not the chrome. Report it separately rather than averaging it in.
- The harness asserts all routes render byte-identical HTML and aborts if not. If it aborts,
  the comparison is meaningless — fix the views, do not report the numbers.

---

## 2026-08-25 — Apple M3, 8 cores, macOS 26.5.2

view_bind 0.1.0 @ `98d0c84` **plus uncommitted working-tree changes** to `lib/view_bind.rb`,
`lib/view_bind/helper.rb`, `lib/view_bind/tracker.rb`.
Rails 8.1.3.1, Ruby 3.4.5 +YJIT. PostgreSQL 17.0 (DBngin) on localhost.
`env=production  eager_load=true  cache_template_loading=true  reloading=false`
`5 rounds x 20 full requests, interleaved, best round per case`

15 runs total (5 per configuration). No abort in any run; HTML verified byte-identical across
all 5 routes every time (182 294 bytes SQLite, 182 291 Postgres).

### SQLite — counters attached only for the inspection pass

| case | med ms | gc ms | objects | obj x | time x |
| --- | ---: | ---: | ---: | ---: | ---: |
| render everywhere (baseline) | 11.202 | 1.20 | 68 360 | 1.00x | 1.00x |
| bind_render in the view | 4.475 | 0.35 | 22 344 | 3.06x | 2.50x |
| bind_render in the layout | 10.278 | 1.10 | 67 349 | 1.02x | 1.09x |
| bind_render in both | 4.282 | 0.30 | 21 325 | **3.21x** | 2.62x |
| + memoised subtree | 4.265 | 0.30 | 19 943 | **3.43x** | 2.63x |

Headline: **3.21x fewer objects, ~2.6x faster** for `bind_render` in both view and layout.

### PostgreSQL 17 — counters attached only for the inspection pass

| case | med ms | gc ms | objects | obj x | time x |
| --- | ---: | ---: | ---: | ---: | ---: |
| render everywhere (baseline) | 18.636 | 1.35 | 68 964 | 1.00x | 1.00x |
| bind_render in the view | 11.167 | 0.40 | 22 949 | 3.01x | 1.67x |
| bind_render in the layout | 18.413 | 1.30 | 67 953 | 1.01x | 1.01x |
| bind_render in both | 11.549 | 0.40 | 21 929 | **3.14x** | 1.61x |
| + memoised subtree | 12.099 | 0.45 | 20 547 | **3.36x** | 1.54x |

Same allocation win, wall-clock ratio down to ~1.6x — the ~7 ms of query time lands on every
route alike. `+ memoised subtree` medians *slower* in ms than `bind_render in both` here
(12.099 vs 11.549) while allocating 1 382 fewer objects: that is noise, not a regression. It is
the least-allocating case in all three configurations.

### SQLite, APM=1 — counters attached while timing

| case | med ms | gc ms | objects | obj x | time x |
| --- | ---: | ---: | ---: | ---: | ---: |
| render everywhere (baseline) | 14.186 | 1.40 | 82 694 | 1.00x | 1.00x |
| bind_render in the view | 4.490 | 0.30 | 22 671 | 3.65x | 3.16x |
| bind_render in the layout | 13.826 | 1.35 | 81 389 | 1.02x | 1.03x |
| bind_render in both | 4.296 | 0.30 | 21 358 | **3.87x** | 3.30x |
| + memoised subtree | 4.279 | 0.30 | 19 976 | **4.14x** | 3.32x |

A subscriber on `render_partial.action_view` costs the baseline +14 334 objects (2 662 events)
and the bound page +33 (1 event). An app running Skylight / Datadog / New Relic / Scout gets
the bigger number, not the smaller one.

### Caveats measured in this session

- **Object counts are stable within a batch of runs, not across processes.** An earlier batch
  the same day, same tree, no code change between them, produced bind-path counts ~200 lower:
  bind_view 22 143 (vs 22 344), bind_both 21 119 (vs 21 325), memo 19 737 (vs 19 943).
  Baseline was identical in both batches (68 360 / 68 964 / 82 694), so the drift is in the
  bind path only. Ratios moved in the third digit (3.24x → 3.21x), so headline claims survive,
  but do not assert the counts are invariant across sessions — they were not.
- **One 1-object jitter within a batch**: Postgres `bind_render in the view` read 22 949 in
  four runs and 22 948 in one. The only non-identical column across 15 runs.
- ms spread this session: baseline SQLite 10.32-11.31, Postgres 18.05-18.82, APM 13.81-14.27.
- `rake test`: 37 runs, 71 assertions, 0 failures, 0 errors, 0 skips.
- The numbers in `README.md`'s benchmark section are from an **earlier tree** (baseline
  68 342, bind_both 20 689, 3.30x) and do not match this session. Not reconciled here.

---

## 2026-08-25, 19:49 EEST — same machine, same tree, repeat measurement

Apple M3, 8 cores, macOS 26.5.2. view_bind 0.1.0 @ `98d0c84` plus the same uncommitted changes
to `lib/view_bind.rb`, `lib/view_bind/helper.rb`, `lib/view_bind/tracker.rb` as the section
above. Rails 8.1.3.1, Ruby 3.4.5 +YJIT. PostgreSQL 17.0 (DBngin) on localhost.
`env=production  eager_load=true  cache_template_loading=true  reloading=false`
`5 rounds x 20 full requests, interleaved, best round per case`

15 runs (5 per configuration). No abort; HTML byte-identical across all 5 routes every run
(182 294 bytes SQLite, 182 291 Postgres).

### SQLite — counters attached only for the inspection pass

| case | med ms | gc ms | objects | obj x | time x |
| --- | ---: | ---: | ---: | ---: | ---: |
| render everywhere (baseline) | 11.929 | 1.30 | 68 360 | 1.00x | 1.00x |
| bind_render in the view | 4.731 | 0.40 | 22 344 | 3.06x | 2.52x |
| bind_render in the layout | 11.794 | 1.30 | 67 349 | 1.02x | 1.01x |
| bind_render in both | 4.612 | 0.35 | 21 325 | **3.21x** | 2.59x |
| + memoised subtree | 4.537 | 0.30 | 19 943 | **3.43x** | 2.63x |

### PostgreSQL 17 — counters attached only for the inspection pass

| case | med ms | gc ms | objects | obj x | time x |
| --- | ---: | ---: | ---: | ---: | ---: |
| render everywhere (baseline) | 17.906 | 1.40 | 68 964 | 1.00x | 1.00x |
| bind_render in the view | 10.959 | 0.45 | 22 949 | 3.01x | 1.63x |
| bind_render in the layout | 17.718 | 1.35 | 67 953 | 1.01x | 1.01x |
| bind_render in both | 10.776 | 0.40 | 21 929 | **3.14x** | 1.66x |
| + memoised subtree | 10.706 | 0.40 | 20 547 | **3.36x** | 1.67x |

The `+ memoised subtree` inversion seen in the previous session (memo slower in ms than
`bind_render in both`) did not reproduce: 10.706 vs 10.776 here, ordered as expected. Confirms
it was noise.

### SQLite, APM=1 — counters attached while timing

| case | med ms | gc ms | objects | obj x | time x |
| --- | ---: | ---: | ---: | ---: | ---: |
| render everywhere (baseline) | 14.210 | 1.45 | 82 694 | 1.00x | 1.00x |
| bind_render in the view | 4.534 | 0.35 | 22 671 | 3.65x | 3.13x |
| bind_render in the layout | 13.718 | 1.40 | 81 389 | 1.02x | 1.04x |
| bind_render in both | 4.260 | 0.30 | 21 358 | **3.87x** | 3.34x |
| + memoised subtree | 4.267 | 0.30 | 19 976 | **4.14x** | 3.33x |

### Correction to the drift caveat above

**Every object count in this session matches the previous section exactly** — all 15 cells,
all three configurations, including the Postgres `bind_render in the view` cell that showed a
1-object jitter last time (22 949 in all 5 runs now). The ~200-object bind-path drift recorded
in the previous section was a one-off between the first and second batch of the day and **did
not reproduce**. Cause still unidentified; the counts are reproducible across processes as of
these two sessions. Treat the earlier caveat as an unexplained single observation, not as a
standing property of the benchmark.

ms spread this session: baseline SQLite 11.31-12.23, Postgres 17.49-18.27, APM 13.95-15.79.
Object-derived ratios are unchanged to three digits; only wall-clock moved.

`rake test` not re-run this session; last result 37 runs, 71 assertions, 0 failures.
