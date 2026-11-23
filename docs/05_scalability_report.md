# CP4 Scalability Benchmark Report

## Scope and dataset

The official `large_data.zip` release was downloaded from the faculty repository and loaded into PostgreSQL 17.12 using `sql/02_load_data.sql` with only the folder changed to `large_data/`. Both benchmark databases used the same PostgreSQL settings:

- `shared_buffers`: 128 MB
- `work_mem`: 4 MB
- `jit`: on
- PostgreSQL: 17.12
- Machine: macOS, Apple Silicon

Verified large-table counts were:

| Table | Rows |
|---|---:|
| viewing_activity | 4,012,819 |
| profiles | 1,500,000 |
| accounts | 500,000 |
| invoices | 2,657,600 |

Both databases received `sql/05_indexes.sql` and `ANALYZE`. The original database kept the unpartitioned `viewing_activity` table. The second database received `sql/08_partitioning.sql`, migrated as a cutover, and uses monthly `RANGE` partitions on `started_at`.

## Benchmark method

The project benchmark script, `benchmarks/run_benchmark.sh`, was used with `sql/06_optimized_queries.sql` and three runs per query. Reads and writes are wrapped according to the script. Raw plans are retained in `benchmarks/results/large_original/` and `benchmarks/results/large_partitioned/`.

The runs for R19-R30 could not be completed before the submission cutoff. They are therefore **not included or estimated** in this report. The following table contains only measured R01-R18 large-dataset timings.

## Large-dataset results

| Query | Seed optimized (ms) | Large original (ms) | Large partitioned (ms) | Partition change |
|---|---:|---:|---:|---:|
| R01 | 0.041 | 0.402 | 2.455 | +510.45% |
| R02 | 0.047 | 0.466 | 0.158 | -66.09% |
| R03 | 0.443 | 18.668 | 15.552 | -16.69% |
| R04 | 0.253 | 7.969 | 6.971 | -12.52% |
| R05 | 0.692 | 21.153 | 16.171 | -23.55% |
| R06 | 0.036 | 0.156 | 0.142 | -8.97% |
| R07 | 0.020 | 0.137 | 0.125 | -8.76% |
| R08 | 1.642 | 64.332 | 41.940 | -34.81% |
| R09 | 22.406 | 356.226 | 540.909 | +51.84% |
| R10 | 0.035 | 0.220 | 0.177 | -19.55% |
| R11 | 2.740 | 70.871 | 75.324 | +6.28% |
| R12 | 0.671 | 18.521 | 20.127 | +8.67% |
| R13 | 16.755 | 0.243 | 0.102 | -58.02% |
| R14 | 18.727 | 332.509 | 583.579 | +75.49% |
| R15 | 3.946 | 33.904 | 43.622 | +28.66% |
| R16 | 120.962 | 1901.788 | 2214.867 | +16.46% |
| R17 | 4.917 | 69.186 | 77.614 | +12.18% |
| R18 | 23.679 | 268.988 | 221.304 | -17.73% |

Seed timings are retained from `benchmarks/results/optimized/summary.csv`. Partition change is `(partitioned/original - 1) * 100`.

## Findings

- R16 is the clear large-scale bottleneck at 1.90 s original and 2.21 s partitioned. It performs a full activity scan and joins profiles, accounts, and plans.
- R14 and R09 are full-table analytics over `viewing_activity` and become slower under partitioning because PostgreSQL scans every partition.
- R18 improved because the monthly partitions provide a better physical layout and several partitions can be pruned.
- R03 and R08 benefit from partition pruning for date ranges.
- R01 is not a partition success case: it has no useful date constraint, so PostgreSQL considered many partition indexes and the partitioned plan was slower.
- R13's small timing is an episode lookup case and is not representative of large table growth.

## Bottlenecks and limitations

Monthly partitioning helps only for queries that constrain `started_at`. It does not improve profile-only, no-date, or whole-table analytics. At 4,012,819 rows, R09/R14/R16 trigger full or near-full scans; partitioning increases plan and append overhead unless a time predicate prunes partitions.

Additional limitations:

- The benchmark environment had only 128 MB `shared_buffers`.
- Warm versus cold cache behavior is not isolated.
- Query cache and OS page cache effects are possible despite repeated runs.
- No dedicated partition benchmark WQL queries or R19-R30 plan data are available in the cutoff run.
- Large partitions without a `started_at` predicate should use local access patterns or direct table routing rather than global scans.

## Partitioning

The implemented partition key is `started_at` with monthly `RANGE` partitions and a default partition. This is appropriate for time-bounded viewing, retention, and monthly analytics. Partition pruning is demonstrated by R03 and R08 plans. PostgreSQL partitioned primary keys require the partition key in the primary key. The migration uses `(view_id, started_at)`, with a separate `view_id` registry to enforce uniqueness across partitions:

```sql
CREATE TABLE netflix.viewing_activity (
    view_id INTEGER NOT NULL,
    ...
    started_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (view_id, started_at)
) PARTITION BY RANGE (started_at);
```

Example pruning:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM netflix.viewing_activity
WHERE started_at >= TIMESTAMPTZ '2026-06-30 00:00:00+00'
  AND started_at < TIMESTAMPTZ '2026-07-01 00:00:00+00';
```

## 100x architecture

At 100x scale, partition by monthly `started_at` for lifecycle and pruning. Sharding is not appropriate by title: Top 10 and Originals require all-title aggregation and would cause cross-shard fan-out. Sharding by `profile_id` keeps Continue Watching local but does not support account-wide or title-wide reports. Sharding by `account_id` is a reasonable ownership boundary because profiles belong to accounts and member-facing operations are local. It does not keep one title local, so Top 10 and Originals should use an analytics replica or precomputed reporting store.

At this scale, a two-tier design is recommended:

- PostgreSQL operational shards partitioned by account/profile and append-only viewing partitions
- Read replicas for operational reads
- Denormalized title/account aggregates for cross-shard analytics
- Batch/warehouse workloads separated from transaction workloads
