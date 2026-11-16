-- Phase 2: Urban Company Schema
-- File: sql/01_schema.sql
BEGIN;

DROP SCHEMA IF EXISTS uc CASCADE;
CREATE SCHEMA uc;
SET search_path TO uc;

-- 1. cities (10 rows)
CREATE TABLE cities (
    city_id   SMALLINT PRIMARY KEY,
    city_name VARCHAR(50) NOT NULL UNIQUE,
    state     VARCHAR(50) NOT NULL
);

-- 2. service_categories (10 rows)
CREATE TABLE service_categories (
    category_id   SMALLINT PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL UNIQUE
);

-- 3. services (60 rows)
CREATE TABLE services (
    service_id   SMALLINT PRIMARY KEY,
    category_id  SMALLINT NOT NULL REFERENCES service_categories(category_id) ON DELETE RESTRICT,
    service_name VARCHAR(120) NOT NULL,
    duration_min SMALLINT NOT NULL,
    base_price   NUMERIC(10, 2) NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_service_name_per_cat UNIQUE (category_id, service_name),
    CONSTRAINT chk_service_duration CHECK (duration_min > 0),
    CONSTRAINT chk_service_price CHECK (base_price > 0)
);

-- 4. professionals (2,500 rows)
CREATE TABLE professionals (
    pro_id       INTEGER PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    phone        VARCHAR(15) NOT NULL UNIQUE,
    city_id      SMALLINT NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    gender       CHAR(1) NOT NULL,
    joined_on    DATE NOT NULL,
    rating       NUMERIC(3, 2),
    kyc_verified BOOLEAN NOT NULL DEFAULT FALSE,
    status       VARCHAR(20) NOT NULL,
    CONSTRAINT chk_pro_gender CHECK (gender IN ('M', 'F')),
    CONSTRAINT chk_pro_rating CHECK (rating IS NULL OR (rating >= 1.00 AND rating <= 5.00)),
    CONSTRAINT chk_pro_status CHECK (status IN ('ACTIVE', 'SUSPENDED', 'OFFBOARDED'))
);

-- 5. pro_skills (5,000 rows)
CREATE TABLE pro_skills (
    pro_id       INTEGER NOT NULL REFERENCES professionals(pro_id) ON DELETE CASCADE,
    category_id  SMALLINT NOT NULL REFERENCES service_categories(category_id) ON DELETE RESTRICT,
    certified_on DATE NOT NULL,
    PRIMARY KEY (pro_id, category_id)
);

-- 6. pro_availability (70,407 rows)
CREATE TABLE pro_availability (
    pro_id     INTEGER NOT NULL REFERENCES professionals(pro_id) ON DELETE CASCADE,
    work_date  DATE NOT NULL,
    start_time TIME NOT NULL,
    end_time   TIME NOT NULL,
    PRIMARY KEY (pro_id, work_date),
    CONSTRAINT chk_avail_time_order CHECK (end_time > start_time)
);

-- 7. customers (40,000 rows)
CREATE TABLE customers (
    customer_id      INTEGER PRIMARY KEY,
    full_name        VARCHAR(100) NOT NULL,
    phone            VARCHAR(15) NOT NULL UNIQUE,
    email            VARCHAR(150) UNIQUE,
    city_id          SMALLINT NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    plus_valid_until DATE,
    created_at       TIMESTAMPTZ NOT NULL
);

-- 8. bookings (150,000 rows)
CREATE TABLE bookings (
    booking_id       BIGINT PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    service_id       SMALLINT NOT NULL REFERENCES services(service_id) ON DELETE RESTRICT,
    pro_id           INTEGER REFERENCES professionals(pro_id) ON DELETE RESTRICT,
    city_id          SMALLINT NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    pincode          VARCHAR(10) NOT NULL,
    booked_at        TIMESTAMPTZ NOT NULL,
    scheduled_start  TIMESTAMPTZ NOT NULL,
    scheduled_end    TIMESTAMPTZ NOT NULL,
    started_at       TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    status           VARCHAR(30) NOT NULL,
    price            NUMERIC(10, 2) NOT NULL,
    discount         NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    cancellation_fee NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    tip              NUMERIC(10, 2),
    payment_method   VARCHAR(20) NOT NULL,
    CONSTRAINT chk_booking_status CHECK (
        status IN ('REQUESTED', 'ASSIGNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED_BY_CUSTOMER', 'CANCELLED_BY_PRO', 'NO_SHOW')
    ),
    CONSTRAINT chk_booking_payment CHECK (
        payment_method IN ('UPI', 'CASH', 'CARD', 'WALLET')
    ),
    CONSTRAINT chk_slot_after_booking CHECK (scheduled_start >= booked_at),
    CONSTRAINT chk_slot_end_after_start CHECK (scheduled_end > scheduled_start),
    CONSTRAINT chk_job_end_after_start CHECK (
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
        (status = 'REQUESTED' AND pro_id IS NULL AND started_at IS NULL AND completed_at IS NULL) OR
        (status = 'COMPLETED' AND pro_id IS NOT NULL AND started_at IS NOT NULL AND completed_at IS NOT NULL) OR
        (status IN ('ASSIGNED', 'NO_SHOW', 'CANCELLED_BY_PRO') AND pro_id IS NOT NULL AND started_at IS NULL AND completed_at IS NULL) OR
        (status = 'IN_PROGRESS' AND pro_id IS NOT NULL AND started_at IS NOT NULL AND completed_at IS NULL) OR
        (status = 'CANCELLED_BY_CUSTOMER' AND started_at IS NULL AND completed_at IS NULL)
    )
);

-- 9. reschedules (5,391 rows)
CREATE TABLE reschedules (
    reschedule_id INTEGER PRIMARY KEY,
    booking_id    BIGINT NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
    old_start     TIMESTAMPTZ NOT NULL,
    new_start     TIMESTAMPTZ NOT NULL,
    requested_by  VARCHAR(15) NOT NULL,
    reason        TEXT,
    created_at    TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_reschedule_by CHECK (requested_by IN ('CUSTOMER', 'PRO')),
    CONSTRAINT chk_reschedule_changed CHECK (new_start <> old_start)
);

-- 10. reviews (76,539 rows)
CREATE TABLE reviews (
    booking_id          BIGINT PRIMARY KEY REFERENCES bookings(booking_id) ON DELETE CASCADE,
    rating_for_pro      SMALLINT NOT NULL,
    comment             TEXT,
    rating_for_customer SMALLINT,
    created_at          TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_review_pro_rating CHECK (rating_for_pro BETWEEN 1 AND 5),
    CONSTRAINT chk_review_cust_rating CHECK (rating_for_customer IS NULL OR (rating_for_customer BETWEEN 1 AND 5))
);

-- 11. payouts (27,015 rows)
CREATE TABLE payouts (
    payout_id      BIGINT PRIMARY KEY,
    pro_id         INTEGER NOT NULL REFERENCES professionals(pro_id) ON DELETE RESTRICT,
    week_start     DATE NOT NULL,
    jobs           INTEGER NOT NULL,
    gross_earnings NUMERIC(12, 2) NOT NULL,
    commission     NUMERIC(12, 2) NOT NULL,
    net_payout     NUMERIC(12, 2) NOT NULL,
    status         VARCHAR(15) NOT NULL,
    paid_at        TIMESTAMPTZ,
    CONSTRAINT uq_payout_pro_week UNIQUE (pro_id, week_start),
    CONSTRAINT chk_payout_monday CHECK (EXTRACT(ISODOW FROM week_start) = 1),
    CONSTRAINT chk_payout_jobs_pos CHECK (jobs > 0),
    CONSTRAINT chk_payout_net_math CHECK (net_payout = gross_earnings - commission),
    CONSTRAINT chk_payout_status_paid CHECK (
        (status = 'PAID' AND paid_at IS NOT NULL) OR
        (status = 'PENDING' AND paid_at IS NULL)
    )
);

COMMIT;