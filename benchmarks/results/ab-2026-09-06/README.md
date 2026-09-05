## 2026-09-06 — ApacheBench through production Puma

Code: `1835a61`. Ruby 3.4.4 + YJIT, Rails 8.1.3.1, Puma 8.0.2, macOS arm64.
SQLite; production; eager_load=true; cache_template_loading=true; LOG_LEVEL=info;
ViewBind profiling off; synthetic APM counters off. One Puma process, max 5 threads.

Each URL received 20 warmup requests, followed by five runs of 200 requests at concurrency 2.
Run order alternated baseline/bound and bound/baseline. No HTTP keep-alive flag was supplied.
Both URLs rendered equivalent HTML before and after the benchmark after timestamp normalization.
All 2,000 measured requests completed with zero failures and no non-2xx responses.

| URL | Median requests/sec | Median AB mean request ms | Median run p95 ms |
| --- | ---: | ---: | ---: |
| `/?per=200` | 103.88 | 19.253 | 21 |
| `/bind_both?per=200` | 229.40 | 8.719 | 11 |

Bound rendering delivered 2.21x throughput (+120.8%) and 54.7% lower mean request time.
The p95 column is the median of five per-run percentiles, not a pooled percentile.
ApacheBench does not measure Ruby allocations; no allocation ratio is inferred from this run.
These are local HTTP results for the 200-card fixture, not a general application speedup.
INFO output was redirected to a file, so interactive terminal logging costs may differ.

```sh
RAILS_ENV=production LOG_LEVEL=info bin/rails s -b 127.0.0.1 -p 3000
ab -n 200 -c 2 'http://127.0.0.1:3000/?per=200'
ab -n 200 -c 2 'http://127.0.0.1:3000/bind_both?per=200'
```

Raw outputs are in the accompanying ten `.txt` files; settings and all samples are in `summary.json`.
