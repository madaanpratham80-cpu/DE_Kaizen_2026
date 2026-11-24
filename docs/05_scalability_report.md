# Phase 5: Scalability & Architecture Report (CP4)

**Team:** T0134 (Kaizen)  
**Project:** Urban Company Home Services  
**Database:** PostgreSQL 18 (`uc` schema)

---

## 1. Overview

In Phase 4, our indexes and query rewrites brought the total runtime of all 30 queries on the seed dataset (150,000 bookings) down to **127.89 ms**. For Phase 5, we tested how well that same setup holds up when the database grows **20x** larger (**7.53 million total rows**, including **3,000,000 bookings**).

Below, we compare the actual Seed vs. Large timings, look at which queries broke or slowed down at 20x scale, and outline a practical plan for scaling the database to **100x** (15M+ bookings).

---

## 2. Database Size at 20x Scale

We loaded `large_data.zip` into a separate `urbancompany_large` database, applied `sql/05_indexes.sql`, and measured the actual disk size of every table using `pg_relation_size`:

| Table | Rows | Table Size | Index Size | Total Size |
|---|---:|---:|---:|---:|
| `bookings` | 3,000,000 | 398 MB | 1,455 MB | 1,853 MB |
| `reviews` | 1,535,227 | 96 MB | 118 MB | 214 MB |
| `customers` | 800,000 | 68 MB | 86 MB | 154 MB |
| `pro_availability` | 1,397,530 | 70 MB | 83 MB | 153 MB |
| `payouts` | 536,303 | 45 MB | 29 MB | 74 MB |
| `reschedules` | 106,306 | 9,792 kB | 7,232 kB | 17 MB |
| `pro_skills` | 100,001 | 4,328 kB | 4,416 kB | 8,776 kB |
| `professionals` | 50,000 | 4,136 kB | 4,456 kB | 8,624 kB |
| `services` | 60 | 8,192 bytes | 48 kB | 88 kB |
| `cities` | 10 | 8,192 bytes | 32 kB | 72 kB |
| `service_categories` | 10 | 8,192 bytes | 32 kB | 72 kB |
| **Total** | **7,525,447** | **~695 MB** | **~1,787 MB** | **~2.48 GB** |

**Main takeaway:** `bookings` takes up **1.85 GB** by itself, and its indexes (**1,455 MB**) are more than **3.6x** larger than the actual table data (398 MB). On the seed dataset everything fit comfortably in memory, whereas at 20x scale it spills past PostgreSQL's default 128 MB `shared_buffers`.

---

## 3. Benchmark Results: Seed (150k) vs. Large (3M Bookings)

Every query in `sql/06_optimized_queries.sql` was run 3 times with `EXPLAIN (ANALYZE, BUFFERS)`. Raw plans are saved in `benchmarks/results/large/`.

| Query | Type | Seed Avg (ms) | Large Avg (ms) | Slowdown | Large Median (ms) | Notes |
|---|:---:|---:|---:|---:|---:|---|
| **R01** | READ | 0.073 | 1.134 | 15.53x | 0.175 | Run 1 was cold (`3.087 ms`); warm median stays < 0.2 ms |
| **R02** | READ | 0.339 | 4.569 | 13.48x | 0.504 | Run 1 was cold (`12.734 ms`); warm median stays ~0.5 ms |
| **R03** | READ | 0.230 | 0.499 | 2.17x | 0.188 | Scaled very well via Index Only Scan |
| **R04** | READ | 0.044 | 0.297 | 6.75x | 0.123 | Fast Index Scan on `(pro_id, scheduled_start)` |
| **R05** | READ | 0.102 | 0.575 | 5.64x | 0.272 | Fast partial index on `REQUESTED` bookings |
| **R06** | READ | 0.032 | 0.315 | 9.84x | 0.122 | Direct unique index lookup on 800k customers |
| **R07** | READ | 0.217 | 0.399 | 1.84x | 0.170 | Nearly constant time for 1 partner's week |
| **R08** | READ | 0.688 | 32.444 | 47.16x | 31.814 | `Seq Scan` on 50k `professionals` + 20x pending payouts |
| **R09** | READ | 1.821 | 84.700 | 46.51x | 70.865 | Scans 20x more June completed rows |
| **R10** | READ | 13.590 | 298.875 | 21.99x | 258.525 | Linear ~22x growth; aggregates across all 50k pros |
| **R11** | READ | 0.811 | 74.840 | 92.28x | 46.350 | **Plan changed:** Index Only Scan -> Bitmap Heap Scan |
| **R12** | READ | 0.884 | 73.478 | 83.12x | 68.714 | Larger partial index for discounted 2026 bookings |
| **R13** | READ | 0.776 | 62.718 | 80.82x | 60.028 | **Plan changed:** Index Scan -> Seq Scan on `professionals` |
| **R14** | READ | 21.422 | 510.754 | 23.84x | 499.130 | Linear ~24x growth across Bengaluru bookings |
| **R15** | READ | 14.126 | 401.099 | 28.39x | 301.361 | Still does a `Seq Scan` on `bookings` (398 MB) |
| **R16** | READ | 0.388 | 10.060 | 25.93x | 8.715 | Linear ~26x growth using covering index |
| **R17** | READ | 12.021 | 875.602 | 72.84x | 789.495 | Big `GROUP BY` across 800k customers |
| **R18** | READ | 0.191 | 4.333 | 22.69x | 0.619 | Run 1 was cold (`11.764 ms`); warm median is `0.619 ms` |
| **R19** | READ | 18.765 | 920.406 | 49.05x | 929.077 | Slowest read; still runs a `Seq Scan` on `bookings` |
| **R20** | READ | 1.846 | 79.082 | 42.84x | 71.696 | Scans 20x more June completed jobs for daily GMV |
| **R21** | READ | 10.534 | 853.311 | 81.01x | 783.817 | Heavy anti-join across all completed jobs and 100k skills |
| **R22** | READ | 7.078 | 26.998 | 3.81x | 23.229 | Only 3.8x slower because `OFFSET 100000` is a fixed skip |
| **R23** | READ | 0.064 | 0.462 | 7.22x | 0.142 | Direct primary key lookup (`bookings_pkey`) |
| **R24** | READ | 0.401 | 12.924 | 32.23x | 10.344 | Partial index scan on rows with cancellation fees |
| **R25** | READ | 3.210 | 226.689 | 70.62x | 200.357 | 20x availability rows + `Seq Scan` on `professionals` |
| **W01** | WRITE | 1.249 | 19.680 | 15.76x | 9.292 | Slower insert due to updating many indexes on `bookings` |
| **W02** | WRITE | 0.660 | 5.600 | 8.48x | 4.365 | Single-row dispatch update via partial index |
| **W03** | WRITE | 0.499 | 0.169 | 0.34x | 0.172 | Single-row partner update; stayed under 0.2 ms |
| **W04** | WRITE | 3.214 | 375.013 | 116.68x | 184.072 | Batch inserts 20x more payout rows into 536k `payouts` |
| **W05** | WRITE | 12.615 | 1,477.672 | 117.14x | 562.828 | Slowest query overall; bulk update hits 1.45 GB of indexes |
| **READ Total** | **25** | **109.653** | **4,556.563** | **41.55x** | — | Mostly driven by `R19`, `R17`, `R21`, `R14`, `R15` |
| **WRITE Total** | **5** | **18.237** | **1,878.134** | **102.98x** | — | Mostly driven by batch writes `W05` and `W04` |
| **All 30 Total** | **30** | **127.890** | **6,434.697** | **50.31x** | — | ~6.43 seconds total across 7.53M rows |

---

## 4. What Worked Well vs. What Broke at 20x Scale

### What Scaled Well
* **Everyday app screens (`R03`, `R04`, `R05`, `R06`, `R07`, `R23`, `W03`):** Every single one stayed **under 0.6 ms** even with 3M bookings. B-tree indexes kept these lookups fast.
* **Cold cache vs. warm cache (`R01`, `R02`, `R18`):** Their averages jumped only because Run 1 had to pull pages from disk. Once cached, their medians stayed **0.175 ms**, **0.504 ms**, and **0.619 ms**.
* **Pagination (`R22`):** Only slowed down by **3.81x** (`7.08 ms` to `27.00 ms`) because `OFFSET 100000` walks the same fixed number of entries in `idx_bookings_booked_at_desc`.

### What Slowed Down or Broke
1. **Heavy index overhead on bulk writes (`W05` and `W04`):**
   `W05` jumped **117x** (from `12.6 ms` to `1,477.7 ms`, with Run 1 taking `3.57 s`). Because `bookings` has 1.45 GB of indexes, updating thousands of `ASSIGNED` rows to `NO_SHOW` forces PostgreSQL to update multiple B-tree indexes at once. `W04` also jumped **117x** (`3.2 ms` to `375.0 ms`) as it inserts 20x more weekly payout rows.
2. **Query plan flips (`R11` and `R13`):**
   * On `R11` (**92x slower**), PostgreSQL stopped using an `Index Only Scan` on `reschedules` and switched to a `Bitmap Heap Scan` once the table grew to 106k rows.
   * On `R13` (**81x slower**), PostgreSQL switched from an `Index Scan` to a `Seq Scan` on `professionals` now that it has 50k rows.
3. **Remaining `Seq Scan`s on `bookings` (`R19` and `R15`):**
   * `R19` (`920.4 ms`) still does a full `Seq Scan` on the 398 MB `bookings` table to compute each professional's `last_job_at`.
   * `R15` (`401.1 ms`) does a `Seq Scan` on `bookings` when joining June reviews to find `pro_id`.
4. **Large `GROUP BY` aggregations (`R17`, `R14`, `R10`):**
   `R17` jumped **73x** (`12.0 ms` to `875.6 ms`) because grouping completed bookings across 800,000 customers creates a large hash table that spills past PostgreSQL's default 4 MB `work_mem`.

---

## 5. Architecture Plan for 100x Scale (15M+ Bookings)

At 100x scale, `bookings` alone would reach **~2 GB of table data and ~7.3 GB of indexes**. Single-table indexing is no longer enough, so we would combine four standard scaling techniques:

### 5.1 Partitioning `bookings` by Time (`sql/08_partitioning.sql`)
* **Design:** Split `uc.bookings` using **Quarterly Range Partitioning on `booked_at`** (one partition per 3 months from 2025 Q1 through 2026 Q4, plus a `bookings_default` fallback partition).
* **Why it helps:**
  1. **Partition pruning:** Queries filtering on a recent month like June 2026 only scan `bookings_2026_q2` and skip the other 7 partitions (skipping ~87.5% of the data).
  2. **Smaller indexes:** Instead of one massive 7.3 GB index set, each quarter has its own smaller local indexes, so the active quarter stays in RAM and writes (`W01`, `W05`) stay fast.
  3. **Easy cleanup:** Old quarters can be detached with `ALTER TABLE bookings DETACH PARTITION ...` instead of running slow `DELETE` queries.
* **PostgreSQL Primary Key rule:** PostgreSQL requires the partition column (`booked_at`) to be inside the primary key. In `sql/08_partitioning.sql`, we changed `bookings`'s PK to `(booking_id, booked_at)` and added `booked_at` to `reviews` and `reschedules` so their foreign keys remain valid.

### 5.2 Sharding Across Multiple Servers
When 15M+ bookings and high write traffic outgrow one database server, we shard horizontally:

| Shard Key Option | Pros | Cons |
|---|---|---|
| **`city_id` (Chosen)** | Customers, pros, and dispatch almost always stay inside one city. | Top cities (Bengaluru, Mumbai, Delhi-NCR) get much more traffic than smaller cities. |
| `pro_id` | Keeps a partner's jobs and payouts together. | Breaks customer history (`R03`) and unassigned dispatch (`R05`). |
| `customer_id` | Keeps a customer's booking history together. | Slot picker (`R02`) and dispatch have to query every shard. |

* **How we would deploy `city_id` sharding:** Give major metros (Bengaluru, Mumbai, Delhi-NCR) their own dedicated shards and group smaller cities onto a shared shard. Copy small lookup tables (`cities`, `services`, `service_categories` — all under 100 kB) onto every shard so joins stay local. Run national finance reports (`R08`, `R12`, `R20`) across shards or on a separate analytics database.

### 5.3 Read Replicas and Caching
Heavy analytics queries (`R17`, `R19`, `R21`) should never compete with live customer bookings or partner updates. We split traffic into four paths:

| Layer | Queries Routed Here | Why |
|---|---|---|
| **Redis Cache** | `R01`, `R06`, `R23` | Repetitive point lookups (service menu, customer phone, booking details) served from RAM in < 1 ms. |
| **Primary DB (Read/Write)** | `W01`–`W05` (and immediate post-write `R03`) | Handles all writes safely with ACID guarantees. |
| **OLTP Read Replicas** | `R02`, `R03`, `R04`, `R05`, `R07`, `R13` | Fast, indexed app screens that offload ~90% of read load from the Primary. |
| **Analytics Replica** | `R08`–`R12`, `R14`–`R22`, `R24`, `R25` | Dedicated read-only server with higher `work_mem` so 500–900 ms reports never slow down live users. |

### 5.4 Practical Maintenance & Tuning
To keep the database healthy over time at 100x volume:
1. **Tune memory:** Increase `shared_buffers` (to keep the current quarter's indexes in RAM) and raise `work_mem` on the analytics replica so big `GROUP BY` queries like `R17` and `R14` don't spill to disk.
2. **Tune autovacuum on `bookings`:** Lower `autovacuum_vacuum_scale_factor` from the default `0.20` (20%) to `0.02` (2%) so dead rows from status updates (`W02`, `W03`, `W05`) are cleaned up before they bloat the table.
3. **Trim redundant indexes & batch bulk updates:** Drop overlapping covering indexes on `bookings` if write latency grows, and run `W05` in smaller batches instead of one giant update.
4. **Automate partitions & summary tables:** Run a scheduled job to create next quarter's partition in advance, archive partitions older than 2 years to cloud storage, and pre-calculate slow metrics (`last_job_at` for `R19`, daily GMV for `R20`, hourly demand for `R14`) in small summary tables.