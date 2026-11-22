# Phase 5: Scalability & Architecture Report (CP4 Deliverable)

**Team:** T0134  
**Database:** PostgreSQL 18.7  
**Schema:** `uc`  
**Current Milestone:** Checkpoint 4 (50% Milestone – Architectural Design & Scalability Planning)

---

## Executive Summary & Milestone Progress

This document fulfills the first **50% of Checkpoint 4 (CP4)** as defined in [`CHECKPOINTS.md`](../CHECKPOINTS.md) and Section 5 of [`README.md`](../README.md).

| Phase / Component | Scope | Status | Notes |
|:---|:---|:---:|:---|
| **DDL Architecture** | `sql/08_partitioning.sql` | **COMPLETED (100%)** | Full range-partitioning DDL with composite PK & local indexes |
| **100× Architecture Design** | Sections 4 & 5 of this report | **COMPLETED (100%)** | Partitioning, sharding, replication, caching, and maintenance |
| **Scalability Bottleneck Analysis** | Section 1 of this report | **COMPLETED (100%)** | Analytical projections for 20× (3M rows) and 100× (15M rows) |
| **Large Dataset Benchmarks** | Results Table & `summary.csv` | **PENDING (Milestone 2)** | To be executed upon 20× large dataset loading |
| **What Broke at Scale** | Empirical Plan Comparisons | **PENDING (Milestone 2)** | To be completed during second half of CP4 |

---

## 1. Scalability Bottleneck Analysis (Projections for 20× and 100× Volume)

In Phase 4, our index strategy reduced overall execution latency across the 30 benchmark queries on the seed data (150,000 bookings) from **19,129.07 ms down to 109.92 ms** (a 174× speedup). However, as transaction volume scales by 20× (3,000,000 bookings) and 100× (15,000,000 bookings), distinct architectural bottlenecks emerge.

### 1.1 Predicted Behavior Across Query Profiles

| Query Profile | Queries | Growth at 20× Scale | Growth at 100× Scale | Primary Limiting Resource |
|:---|:---|:---:|:---:|:---|
| **Point Index Lookups** | `R06`, `R23`, `W01`, `W02`, `W03` | $\mathcal{O}(\log N)$ (~flat) | $\mathcal{O}(\log N)$ (~flat) | Buffer cache hit ratio |
| **Time-Bounded App Feeds** | `R01`, `R02`, `R03`, `R04`, `R05`, `R07` | Near Constant | Constant | Selective index traversal |
| **Sliding Window Analytics** | `R09`, `R11`, `R15`, `R16`, `R18`, `R20`, `W04` | ~20× linear | ~100× linear | Memory bandwidth & HashAggregate memory |
| **Full Historical Scans** | `R10`, `R12`, `R14`, `R17`, `R19`, `R21`, `R24`, `R25` | 20× to 35× | 100× to 150× | CPU cache thrashing & disk I/O |

### 1.2 Specific Critical Bottlenecks

1. **Working Set Exceeding `shared_buffers`:**
   - On the seed dataset, the entire `bookings` table is 20 MB and its indexes occupy 73 MB (total ~93 MB), fitting completely within memory.
   - At 100× volume (15 million bookings), `bookings` heap will reach **~2.0 GB** and total index footprint will expand to **~7.3 GB**.
   - If PostgreSQL memory parameters (`shared_buffers`) are left at default values, random page reads will spill to disk, shifting operations from RAM latencies (~100 ns) to NVMe SSD latencies (~50–100 $\mu$s), degrading performance by 100×–500×.
2. **HashAggregate Memory Spilling (`work_mem`):**
   - Queries like `R10` (no-show rate across all pros), `R14` (demand matrix), and `R17` (customer category frequency) maintain large hash tables in memory.
   - At 20× and 100× volume, grouping across millions of distinct keys will exceed typical `work_mem` allocations (4 MB default), forcing PostgreSQL to spill partitions to temporary disk files via batch hashing, drastically reducing throughput.
3. **Write Amplification & WAL Contention:**
   - Every single booking write (`W01`, `W02`, `W03`) updates table pages and up to 10 distinct B-tree indexes.
   - While partial indexes mitigate indexing overhead for non-matching statuses, high-concurrency inserts at 100× scale introduce significant WAL (Write-Ahead Logging) write lock contention and checkpoint spikes.

---

## 2. Architecture for 100× Scale: Partitioning Strategy

### 2.1 Table and Strategy Selection
- **Target Table:** `uc.bookings`
- **Partitioning Method:** **Declarative RANGE Partitioning**
- **Partition Key:** `booked_at TIMESTAMPTZ`
- **Granularity:** **Quarterly (3-Month Windows)**

```
┌────────────────────────────────────────────────────────────────────────┐
│                        uc.bookings (Parent Table)                      │
│                    PARTITION BY RANGE (booked_at)                      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
       ┌────────────────────────────┼────────────────────────────┐
       ▼                            ▼                            ▼
┌──────────────┐             ┌──────────────┐             ┌──────────────┐
│ bookings_    │             │ bookings_    │             │ bookings_    │
│ 2026_q1      │             │ 2026_q2      │             │ default      │
│ Jan 01-Apr 01│             │ Apr 01-Jul 01│             │ Fallback     │
└──────────────┘             └──────────────┘             └──────────────┘
```

### 2.2 Architectural Justification
1. **Query Alignment:** The overwhelming majority of reporting and analytical queries (`R04`, `R07`, `R09`, `R11`, `R12`, `R15`, `R16`, `R19`, `R20`, `R25`, `W04`) filter by date ranges. By partitioning on `booked_at`, queries addressing specific time horizons (such as June 2026) engage **Declarative Partition Pruning**. The query engine completely ignores 7 out of 8 quarterly partitions, immediately reducing scanned tuple volume by **87.5%**.
2. **Local Index Scalability:** Monolithic indexes of 7.3 GB are broken down into partition-local indexes of ~200–500 MB each. Only active partitions (the current quarter) need to reside in the database buffer pool.
3. **Data Lifecycle & Archival:** When a quarter ages past business retention requirements (e.g. 3 years), the partition can be detached instantaneously via:
   ```sql
   ALTER TABLE bookings DETACH PARTITION bookings_2023_q1;
   ```
   This takes milliseconds with zero table locks, completely bypassing costly `DELETE FROM bookings WHERE ...` transactions which create dead tuples and table bloat.

### 2.3 The Primary-Key Rule for Partitioned Tables in PostgreSQL
Under PostgreSQL declarative partitioning specifications:
> **PostgreSQL Rule:** Every `PRIMARY KEY` or `UNIQUE` constraint declared on a partitioned table must include all columns in the partition key.

- **Consequence for `bookings`:** The primary key is declared as:
  ```sql
  PRIMARY KEY (booking_id, booked_at)
  ```
- **Consequence for Foreign Key Child Tables:**
  - In PostgreSQL 12+, child tables can reference partitioned parent tables, but the foreign key constraint must match the referenced composite unique key.
  - In `sql/08_partitioning.sql`, we implemented **Pattern A** (strict declarative foreign keys):
    `reschedules` and `reviews` have `booked_at` added and constrained via:
    ```sql
    FOREIGN KEY (booking_id, booked_at) REFERENCES bookings(booking_id, booked_at) ON DELETE CASCADE
    ```
  - This ensures compile-time referential integrity, eliminates orphaned records, and allows child table partition joins to prune alongside the parent.

### 2.4 Partition Pruning Demonstration

When executing a query for June 2026 completed jobs (`R09` / `R20`):
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(price - discount)
FROM uc.bookings
WHERE booked_at >= '2026-06-01 00:00:00+05:30'
  AND booked_at <  '2026-07-01 00:00:00+05:30'
  AND status = 'COMPLETED';
```

**Expected Execution Plan with Pruning:**
```text
Aggregate  (cost=425.10..425.11 rows=1 width=40)
  Buffers: shared hit=312
  ->  Index Only Scan using bookings_2026_q2_idx_bookings_completed_sched on bookings_2026_q2
        Index Cond: ((booked_at >= '2026-06-01 00:00:00+05:30') AND (booked_at < '2026-07-01 00:00:00+05:30'))
        Heap Fetches: 0
```
*Partitions `bookings_2025_q1` through `bookings_2026_q1`, `bookings_2026_q3`, and `bookings_default` are pruned at compile time.*

---

## 3. Architecture for 100× Scale: Sharding Strategy

At 100× scale (15M+ bookings, 2.5M professionals, 40M customers across India), horizontal database sharding across multiple physical instances becomes necessary.

### 3.1 Sharding Dimension Comparison

| Candidate Shard Key | Pros | Cons | Cross-Shard Query Penalty |
|:---|:---|:---|:---:|
| **City (`city_id`)** | • **Physical localization:** 95% of operational bookings, service assignments, and availability queries occur strictly within one city.<br>• Clean isolation of regional failure domains. | • **Data Skew:** Tier-1 cities (Bengaluru, Delhi-NCR, Mumbai) account for >60% of volume, creating hot shards. | High for national analytics (`R08`, `R10`, `R12`, `R20`). |
| **Professional (`pro_id`)** | • Localizes partner daily agenda (`R04`), earnings (`R07`), and weekly payouts (`W04`). | • Breaks customer-centric lookups (`R03`, `R06`).<br>• Cannot route unassigned bookings (`R05`, `W02`). | Very High for dispatch and customer workflows. |
| **Customer (`customer_id`)** | • Collocates customer booking history and Plus subscription checks. | • Partner dispatch and slot availability (`R02`) require cross-node broadcast queries across all customer shards. | Catastrophic for dispatch & partner operations. |

### 3.2 Chosen Recommendation: Entity-Colocated Hybrid Sharding by `city_id`
We recommend sharding by **`city_id`** using a distributed coordinator (e.g. Citus Data / PostgreSQL Distributed):
1. **Shard Placement:**
   - Shard 1: Bengaluru (`city_id = 1`)
   - Shard 2: Delhi-NCR (`city_id = 3`)
   - Shard 3: Mumbai (`city_id = 2`)
   - Shard 4: Tier-2 Cities (Remaining cities pooled via consistent hashing)
2. **Reference Tables (Replicated to All Shards):**
   - `services`, `service_categories`, and `cities` are small (<1,000 rows). They are designated as **Distributed Reference Tables**, copied to every shard node to guarantee local zero-latency joins.
3. **Handling Cross-Shard Queries:**
   - **National Finance & Quality Reports (`R08`, `R10`, `R12`, `R15`, `R20`, `R24`):**
     * Executed by the distributed coordinator using scatter-gather map-reduce: parallel subqueries run on each shard node, returning pre-aggregated partial sums/counts to the coordinator for final aggregation.
     * Alternatively, routed asynchronously to a centralized **OLAP Data Lakehouse** (e.g. ClickHouse / BigQuery) fed by Debezium CDC streams.

---

## 4. Architecture for 100× Scale: Read Replicas & Caching Topology

To protect the Primary database node from saturation, read/write segregation and in-memory caching must be enforced across all 30 queries:

```
[ Client Apps / Web ]
         │
         ├─── Write Operations (W01–W05) ─────────────► [ Primary Database Node ]
         │                                                      │
         ├─── Read Cache (Redis) ─── [ R01, R06, R23 ]         │ Streaming Replication
         │                                                      ▼
         └─── Read Replicas (Load Balanced) ──────────► [ Read Replicas (RO) ]
              [ R02–R05, R07–R22, R24–R25 ]
```

### 4.1 Query Routing Matrix

| Tier | Routing Destination | Cache TTL | Assigned Queries | Rationale |
|:---|:---|:---:|:---|:---|
| **L1: In-Memory Cache (Redis)** | Redis Key-Value Store | 10–60 min | `R01` (Service Menu), `R06` (Customer Phone Lookup), `R23` (Static Booking Detail) | Highly repetitive static reads with minimal mutation; sub-millisecond RAM response. |
| **L2: Primary Node (Read-Your-Writes)** | Master PostgreSQL (Read-Write) | None | `W01` (Insert Booking), `W02` (Dispatch Job), `W03` (Finish Job), `W04` (Payout Batch), `W05` (Mark No-Show), and immediate post-write reads (`R03` right after booking) | Strict serializability and ACID consistency; avoids replication lag read anomalies. |
| **L3: Read Replicas (OLTP)** | Synchronous / Async Read Replicas | None | `R02` (Slot Picker), `R03` (Upcoming Bookings), `R04` (Daily Agenda), `R05` (Dispatch Pending), `R07` (Weekly Earnings), `R13` (Zero Cancellations) | Real-time operational queries; offloads 90% of read traffic from the primary writer. |
| **L4: Dedicated Analytics Replica / OLAP** | Read-Only Analytical Node (High `work_mem`) | None | `R08`, `R09`, `R10`, `R11`, `R12`, `R14`, `R15`, `R16`, `R17`, `R18`, `R19`, `R20`, `R21`, `R22`, `R24`, `R25` | Heavy analytical scans and sorting; isolated so analytical spikes never impact customer checkout or partner app latency. |

---

## 5. Architecture for 100× Scale: Database Maintenance & Autovacuum Tuning

At high write throughput, default PostgreSQL autovacuum settings are insufficient, leading to table bloat, index page fragmentation, and query performance degradation.

### 5.1 Autovacuum Tuning Parameters for `bookings`

```ini
# postgresql.conf optimization for high-throughput OLTP
autovacuum = on
autovacuum_max_workers = 6
autovacuum_naptime = 15s
autovacuum_vacuum_cost_limit = 2000
autovacuum_vacuum_cost_delay = 2ms

# Dedicated table-level tuning for bookings partitions
ALTER TABLE uc.bookings SET (
    autovacuum_vacuum_scale_factor = 0.02,      -- Vacuum after 2% row changes (vs 20% default)
    autovacuum_vacuum_threshold = 5000,         -- Trigger threshold
    autovacuum_analyze_scale_factor = 0.01,     -- Analyze after 1% changes
    autovacuum_vacuum_cost_delay = 0            -- Zero delay for aggressive vacuuming
);
```

### 5.2 Automated Maintenance Policies
1. **Partition Maintenance:** A pg_partman / cron job scheduled monthly to pre-create upcoming quarterly partitions and attach appropriate local indexes.
2. **Archival & Purging:** Partitions older than 24 months are detached and converted to cold Parquet storage on object storage (AWS S3 / Google Cloud Storage), keeping the live PostgreSQL working set under 50 GB.
3. **Continuous Summary Tables:** Queries like `R14` (hourly demand planning) and `R20` (daily GMV) should be pre-materialized using continuous aggregation tables or `pg_timetable` incremental updates every 15 minutes, reducing runtime execution from 20 ms to 0.1 ms.

---

## 6. CP4 Execution Roadmap (Milestone 2 Next Steps)

To complete the remaining 50% of Checkpoint 4 upon provision of the 20× large dataset (`large_data.zip`):
1. **Load Large Dataset:** Populate `large_data/` into the PostgreSQL instance and re-run `ANALYZE`.
2. **Execute Benchmark:** Execute `./benchmarks/run_benchmark.sh uc large` using the optimized queries.
3. **Populate Empirical Results:** Fill the 30-query comparison table (Seed vs Large) in Section 1.
4. **Document Empirical Scaling Artifacts:** Record before/after plans for queries that required adjustments under scale, measuring storage expansion via `pg_relation_size`.

*(End of CP4 50% Milestone Deliverable)*
