-- =====================================================================
-- Phase 5 / CP4: Urban Company Database – Partitioning Architecture
-- File: sql/08_partitioning.sql
-- Team: T0134  |  PostgreSQL 18.7  |  Schema: uc
-- =====================================================================
-- 1. SCALABILITY RATIONALE & BOTTLENECK ANALYSIS
-- ─────────────────────────────────────────────────────────────────────
-- In the Urban Company database, `bookings` is the primary high-velocity
-- transactional table (150,000 rows in seed; scaling to 3,000,000 rows at
-- 20× and 15,000,000+ rows at 100× volume).
--
-- Bottlenecks on Monolithic Table at 100× Scale:
--   1. Sequential Scan Degradation: At 15M rows, table heap exceeds 2 GB.
--      Any query doing even a partial table or index range scan suffers
--      from cache thrashing and heavy I/O latency.
--   2. Index Bloat: Monolithic B-tree indexes (e.g. on booked_at, pro_id)
--      grow to several gigabytes each, exceeding shared_buffers and
--      increasing B-tree depth from 3 to 5 levels.
--   3. Maintenance Lock Contention: VACUUM, REINDEX, and ANALYZE operations
--      on a 15M row monolithic table require substantial maintenance_work_mem
--      and take hours, increasing lock contention and transaction wraparound risk.
--
-- ─────────────────────────────────────────────────────────────────────
-- 2. PARTITIONING DESIGN DECISION
-- ─────────────────────────────────────────────────────────────────────
-- Strategy: DECLARATIVE RANGE PARTITIONING on `booked_at`
-- Granularity: Quarterly (3-month intervals)
--
-- Why RANGE on booked_at vs Other Strategies:
--   - vs LIST on city_id: While bookings are city-specific, query filtering
--     predominantly isolates recent time windows (e.g. current week, June 2026).
--     City partitioning still leaves millions of rows per city partition
--     without solving time-based data lifecycle management.
--   - vs HASH on booking_id: HASH distributes rows uniformly but prevents
--     range pruning. A query for "June 2026 bookings" would still scan all
--     hash partitions.
--   - Why RANGE on booked_at:
--     * 20 out of 30 benchmark queries filter by a date or timestamp interval.
--     * Enables declarative Partition Pruning: queries scanning June 2026
--       will scan ONLY `bookings_2026_q2`, completely eliminating 87.5% of
--       the table and index blocks from the query plan.
--     * Data Lifecycle: Older quarters (e.g. 2025) can be detached (`ALTER TABLE
--       DETACH PARTITION`), converted to compressed columnar storage, or moved
--       to cold storage tablespaces without affecting active transactions.
--
-- ─────────────────────────────────────────────────────────────────────
-- 3. THE PRIMARY-KEY RULE FOR PARTITIONED TABLES IN POSTGRESQL
-- ─────────────────────────────────────────────────────────────────────
-- Architectural Constraint:
-- In PostgreSQL (declarative partitioning), any UNIQUE or PRIMARY KEY
-- constraint on a partitioned table MUST contain the partition key column.
--
-- Implications for Urban Company Schema:
--   1. The primary key of `bookings` MUST become `(booking_id, booked_at)`.
--   2. Foreign Key References from Child Tables:
--      Tables like `reschedules` and `reviews` originally referenced
--      `bookings(booking_id)` as a single-column FK.
--      Under PostgreSQL declarative partitioning:
--        - A foreign key referencing a composite PK must supply all PK columns.
--        - In production architectures, two valid patterns exist:
--          Pattern A (Composite FK): Denormalize `booked_at` into `reschedules`
--                    and `reviews`, allowing composite FK enforcement.
--          Pattern B (Global Uniqueness via Trigger/Sequence): Retain
--                    `booking_id` using a global BIGINT sequence (ensuring
--                    cluster-wide uniqueness) and enforce referential integrity
--                    via validation triggers or partition-level constraints.
--      This DDL demonstrates Pattern A (adding `booked_at` to dependent child
--      tables) to maintain 100% strict declarative foreign key integrity.
-- =====================================================================

SET search_path TO uc, public;

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- STEP 1: Archive original monolithic bookings table
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE IF EXISTS bookings RENAME TO bookings_monolithic_archive;

-- ─────────────────────────────────────────────────────────────────────
-- STEP 2: Create Partitioned Parent Table
-- ─────────────────────────────────────────────────────────────────────
CREATE TABLE bookings (
    booking_id       BIGINT        NOT NULL,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id)    ON DELETE RESTRICT,
    service_id       SMALLINT      NOT NULL REFERENCES services(service_id)      ON DELETE RESTRICT,
    pro_id           INTEGER                REFERENCES professionals(pro_id)     ON DELETE RESTRICT,
    city_id          SMALLINT      NOT NULL REFERENCES cities(city_id)           ON DELETE RESTRICT,
    pincode          VARCHAR(10)   NOT NULL,
    booked_at        TIMESTAMPTZ   NOT NULL,
    scheduled_start  TIMESTAMPTZ   NOT NULL,
    scheduled_end    TIMESTAMPTZ   NOT NULL,
    started_at       TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    status           VARCHAR(30)   NOT NULL,
    price            NUMERIC(10,2) NOT NULL,
    discount         NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    cancellation_fee NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    tip              NUMERIC(10,2),
    payment_method   VARCHAR(20)   NOT NULL,

    -- Business Domain Integrity Constraints
    CONSTRAINT chk_booking_status CHECK (
        status IN ('REQUESTED','ASSIGNED','IN_PROGRESS','COMPLETED',
                   'CANCELLED_BY_CUSTOMER','CANCELLED_BY_PRO','NO_SHOW')
    ),
    CONSTRAINT chk_booking_payment CHECK (
        payment_method IN ('UPI','CASH','CARD','WALLET')
    ),
    CONSTRAINT chk_slot_after_booking   CHECK (scheduled_start >= booked_at),
    CONSTRAINT chk_slot_end_after_start CHECK (scheduled_end > scheduled_start),
    CONSTRAINT chk_job_end_after_start  CHECK (
        completed_at IS NULL OR (started_at IS NOT NULL AND completed_at >= started_at)
    ),
    CONSTRAINT chk_discount_le_price CHECK (
        price >= 0 AND discount >= 0 AND discount <= price AND cancellation_fee >= 0
    ),
    CONSTRAINT chk_tip_only_completed CHECK (
        tip IS NULL OR (tip >= 0 AND status = 'COMPLETED')
    ),
    CONSTRAINT chk_cancel_fee_only_cust_cancel CHECK (
        cancellation_fee = 0 OR status = 'CANCELLED_BY_CUSTOMER'
    ),
    CONSTRAINT chk_status_rules CHECK (
        (status = 'REQUESTED'             AND pro_id IS NULL     AND started_at IS NULL AND completed_at IS NULL) OR
        (status = 'COMPLETED'             AND pro_id IS NOT NULL AND started_at IS NOT NULL AND completed_at IS NOT NULL) OR
        (status IN ('ASSIGNED','NO_SHOW','CANCELLED_BY_PRO') AND pro_id IS NOT NULL AND started_at IS NULL AND completed_at IS NULL) OR
        (status = 'IN_PROGRESS'           AND pro_id IS NOT NULL AND started_at IS NOT NULL AND completed_at IS NULL) OR
        (status = 'CANCELLED_BY_CUSTOMER' AND started_at IS NULL AND completed_at IS NULL)
    ),

    -- Required by PostgreSQL: Partition key `booked_at` must be part of PK
    PRIMARY KEY (booking_id, booked_at)
) PARTITION BY RANGE (booked_at);

-- ─────────────────────────────────────────────────────────────────────
-- STEP 3: Create Range Partitions (Quarterly)
-- ─────────────────────────────────────────────────────────────────────

-- 2025 Quarters (Historical)
CREATE TABLE bookings_2025_q1 PARTITION OF bookings
    FOR VALUES FROM ('2025-01-01 00:00:00+00') TO ('2025-04-01 00:00:00+00');

CREATE TABLE bookings_2025_q2 PARTITION OF bookings
    FOR VALUES FROM ('2025-04-01 00:00:00+00') TO ('2025-07-01 00:00:00+00');

CREATE TABLE bookings_2025_q3 PARTITION OF bookings
    FOR VALUES FROM ('2025-07-01 00:00:00+00') TO ('2025-10-01 00:00:00+00');

CREATE TABLE bookings_2025_q4 PARTITION OF bookings
    FOR VALUES FROM ('2025-10-01 00:00:00+00') TO ('2026-01-01 00:00:00+00');

-- 2026 Quarters (Active Operating Window)
CREATE TABLE bookings_2026_q1 PARTITION OF bookings
    FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2026-04-01 00:00:00+00');

CREATE TABLE bookings_2026_q2 PARTITION OF bookings
    FOR VALUES FROM ('2026-04-01 00:00:00+00') TO ('2026-07-01 00:00:00+00');

CREATE TABLE bookings_2026_q3 PARTITION OF bookings
    FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');

CREATE TABLE bookings_2026_q4 PARTITION OF bookings
    FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');

-- Default Partition (Safety net preventing insert failures for future periods)
CREATE TABLE bookings_default PARTITION OF bookings DEFAULT;

-- ─────────────────────────────────────────────────────────────────────
-- STEP 4: Populate Partitioned Table from Archive
-- ─────────────────────────────────────────────────────────────────────
INSERT INTO bookings
SELECT * FROM bookings_monolithic_archive;

-- ─────────────────────────────────────────────────────────────────────
-- STEP 5: Re-create Partition-Local Indexes
-- (In PostgreSQL, creating an index on the parent table propagates it
-- automatically to every individual partition table as local B-trees)
-- ─────────────────────────────────────────────────────────────────────

-- Real-time Operational Indexes
CREATE INDEX IF NOT EXISTS idx_bookings_active_pro_slots
    ON bookings (pro_id, scheduled_start, scheduled_end)
    WHERE status IN ('ASSIGNED','IN_PROGRESS');

CREATE INDEX IF NOT EXISTS idx_bookings_customer_sched
    ON bookings (customer_id, scheduled_start)
    INCLUDE (booking_id, service_id, status, pro_id);

CREATE INDEX IF NOT EXISTS idx_bookings_pro_sched
    ON bookings (pro_id, scheduled_start)
    INCLUDE (scheduled_end, pincode, status, service_id);

CREATE INDEX IF NOT EXISTS idx_bookings_requested
    ON bookings (scheduled_start, booking_id)
    INCLUDE (service_id, city_id)
    WHERE status = 'REQUESTED';

CREATE INDEX IF NOT EXISTS idx_bookings_requested_id
    ON bookings (booking_id)
    WHERE status = 'REQUESTED';

-- Analytical / Reporting Indexes
CREATE INDEX IF NOT EXISTS idx_bookings_pro_completed
    ON bookings (pro_id, completed_at)
    INCLUDE (price, discount, tip)
    WHERE status = 'COMPLETED';

CREATE INDEX IF NOT EXISTS idx_bookings_completed_sched
    ON bookings (scheduled_start)
    INCLUDE (service_id, started_at, pro_id, price, discount)
    WHERE status = 'COMPLETED';

CREATE INDEX IF NOT EXISTS idx_bookings_pro_status
    ON bookings (pro_id, status)
    WHERE pro_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_cancelled_customer
    ON bookings (pro_id)
    WHERE status = 'CANCELLED_BY_CUSTOMER';

CREATE INDEX IF NOT EXISTS idx_bookings_city_sched
    ON bookings (city_id)
    INCLUDE (service_id, scheduled_start);

CREATE INDEX IF NOT EXISTS idx_bookings_city_booked
    ON bookings (city_id, booked_at)
    INCLUDE (pincode);

CREATE INDEX IF NOT EXISTS idx_bookings_discount_booked
    ON bookings (booked_at)
    INCLUDE (discount)
    WHERE discount > 0;

CREATE INDEX IF NOT EXISTS idx_bookings_completed_customer_cat
    ON bookings (booked_at, customer_id, service_id)
    WHERE status = 'COMPLETED';

CREATE INDEX IF NOT EXISTS idx_bookings_booked_at_desc
    ON bookings (booked_at DESC)
    INCLUDE (booking_id, customer_id, service_id, status);

CREATE INDEX IF NOT EXISTS idx_bookings_cancellation_fee
    ON bookings (scheduled_start)
    INCLUDE (cancellation_fee)
    WHERE cancellation_fee > 0;

CREATE INDEX IF NOT EXISTS idx_bookings_pro_last_job
    ON bookings (pro_id, completed_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_bookings_completed_skills
    ON bookings (booking_id)
    INCLUDE (pro_id, service_id)
    WHERE status = 'COMPLETED';

CREATE INDEX IF NOT EXISTS idx_bookings_completed_payout_week
    ON bookings (completed_at, pro_id)
    INCLUDE (price, discount, tip)
    WHERE status = 'COMPLETED';

CREATE INDEX IF NOT EXISTS idx_bookings_assigned_noshow
    ON bookings (scheduled_end)
    WHERE status = 'ASSIGNED' AND started_at IS NULL;

-- ─────────────────────────────────────────────────────────────────────
-- STEP 6: Update Child FK Constraints (Pattern A Implementation)
-- ─────────────────────────────────────────────────────────────────────

-- Add booked_at to reschedules to satisfy PostgreSQL partitioned PK rule
ALTER TABLE reschedules ADD COLUMN IF NOT EXISTS booked_at TIMESTAMPTZ;
UPDATE reschedules r
SET booked_at = b.booked_at
FROM bookings_monolithic_archive b
WHERE r.booking_id = b.booking_id
  AND r.booked_at IS NULL;
ALTER TABLE reschedules ALTER COLUMN booked_at SET NOT NULL;

ALTER TABLE reschedules
    DROP CONSTRAINT IF EXISTS reschedules_booking_id_fkey,
    ADD CONSTRAINT reschedules_booking_id_booked_at_fkey
    FOREIGN KEY (booking_id, booked_at) REFERENCES bookings(booking_id, booked_at)
    ON DELETE CASCADE;

-- Add booked_at to reviews to satisfy PostgreSQL partitioned PK rule
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS booked_at TIMESTAMPTZ;
UPDATE reviews rw
SET booked_at = b.booked_at
FROM bookings_monolithic_archive b
WHERE rw.booking_id = b.booking_id
  AND rw.booked_at IS NULL;
ALTER TABLE reviews ALTER COLUMN booked_at SET NOT NULL;

ALTER TABLE reviews
    DROP CONSTRAINT IF EXISTS reviews_booking_id_fkey,
    ADD CONSTRAINT reviews_booking_id_booked_at_fkey
    FOREIGN KEY (booking_id, booked_at) REFERENCES bookings(booking_id, booked_at)
    ON DELETE CASCADE;

-- Clean up archive
DROP TABLE bookings_monolithic_archive;

COMMIT;

-- ─────────────────────────────────────────────────────────────────────
-- 4. VERIFICATION OF PARTITION PRUNING
-- ─────────────────────────────────────────────────────────────────────
-- Execute EXPLAIN to verify partition pruning:
-- Query filtering Q2 2026 will prune all partitions except bookings_2026_q2:
--
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM uc.bookings
-- WHERE booked_at >= '2026-04-01 00:00:00+00'
--   AND booked_at <  '2026-07-01 00:00:00+00';
--
-- Plan shows:
--   -> Seq Scan / Index Scan on bookings_2026_q2
-- (All other 7 partition tables are excluded from execution entirely!)
-- =====================================================================
