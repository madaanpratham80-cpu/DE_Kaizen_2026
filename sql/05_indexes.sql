-- =====================================================================
-- Phase 4 / CP3: Urban Company Database Optimization Indexes
-- File: sql/05_indexes.sql
-- =====================================================================
SET search_path TO uc, public;

-- Extension required for GIN trigram indexing on text fields (reviews.comment)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------
-- 1. Services & Categories
-- ---------------------------------------------------------------------

-- Query: R01 (Service menu: active AC Repair services, cheapest first)
-- Type: Partial Covering B-tree Index
-- Column Order: (category_id, base_price)
-- Reason: Filters by category_id and sorts by base_price ASC. Filter predicate
-- `WHERE is_active` indexes only active offerings (partial). INCLUDE clause
-- covers (service_name, duration_min), yielding an Index Only Scan with zero heap visits.
CREATE INDEX IF NOT EXISTS idx_services_cat_price 
ON services (category_id, base_price) 
INCLUDE (service_name, duration_min) 
WHERE is_active;

-- ---------------------------------------------------------------------
-- 2. Professional Certifications & Availability
-- ---------------------------------------------------------------------

-- Queries: R02 (Slot picker), R21 (Compliance)
-- Type: Composite B-tree Index
-- Column Order: (category_id, pro_id)
-- Reason: The primary key is (pro_id, category_id). Looking up certified pros by
-- category_id cannot utilize the PK's leading column. This index provides an
-- Index Only Scan when filtering or anti-joining by category_id.
CREATE INDEX IF NOT EXISTS idx_pro_skills_cat_pro 
ON pro_skills (category_id, pro_id);

-- Queries: R02 (Slot picker), R19 (City report), R25 (Capacity)
-- Type: Partial Composite B-tree Index
-- Column Order: (city_id, rating DESC NULLS LAST)
-- Reason: R02 filters active pros in Bengaluru (city_id = 1) ordered by rating.
-- Partial filter `WHERE status = 'ACTIVE'` excludes inactive pros.
CREATE INDEX IF NOT EXISTS idx_pros_city_active_rating 
ON professionals (city_id, rating DESC NULLS LAST) 
INCLUDE (full_name) 
WHERE status = 'ACTIVE';

-- Queries: R02 (Slot picker), R25 (Capacity utilisation)
-- Type: Composite Covering B-tree Index
-- Column Order: (work_date, pro_id, start_time, end_time)
-- Reason: R02 and R25 filter by work_date and pro_id, checking or summing working
-- hours. Storing start_time and end_time enables Index Only Scans on availability.
CREATE INDEX IF NOT EXISTS idx_pro_avail_date_pro 
ON pro_availability (work_date, pro_id, start_time, end_time);

-- ---------------------------------------------------------------------
-- 3. Bookings - Operational Lookups & Clash Detection
-- ---------------------------------------------------------------------

-- Queries: R02 (Slot picker clash check), W03 (Partner job completion)
-- Type: Partial Composite B-tree Index
-- Column Order: (pro_id, scheduled_start, scheduled_end)
-- Reason: Slot clash detection in R02 inspects ASSIGNED and IN_PROGRESS jobs for a pro.
-- Over 95% of bookings are COMPLETED or CANCELLED; indexing only active states keeps
-- the index tiny (<0.5 MB) and fast for NOT EXISTS lookups.
CREATE INDEX IF NOT EXISTS idx_bookings_active_pro_slots 
ON bookings (pro_id, scheduled_start, scheduled_end) 
WHERE status IN ('ASSIGNED', 'IN_PROGRESS');

-- Queries: R03 ("My bookings": customer upcoming bookings)
-- Type: Composite Covering B-tree Index
-- Column Order: (customer_id, scheduled_start)
-- Reason: Equality filter on customer_id, range and sort on scheduled_start.
-- INCLUDE provides booking_id, service_id, status, pro_id for Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_bookings_customer_sched 
ON bookings (customer_id, scheduled_start) 
INCLUDE (booking_id, service_id, status, pro_id);

-- Queries: R04 (Partner daily schedule), R19 (City report), R25 (Capacity)
-- Type: Composite Covering B-tree Index
-- Column Order: (pro_id, scheduled_start)
-- Reason: Equality on pro_id, range scan on scheduled_start. Serves partner app
-- agenda lookups and range aggregations.
CREATE INDEX IF NOT EXISTS idx_bookings_pro_sched 
ON bookings (pro_id, scheduled_start) 
INCLUDE (scheduled_end, pincode, status, service_id);

-- Queries: R05 (Dispatch pending unassigned jobs), W02 (Dispatch assign oldest)
-- Type: Partial Covering B-tree Index
-- Column Order: (scheduled_start, booking_id)
-- Reason: Dispatch needs unassigned requested bookings ordered by scheduled_start.
-- Partial index where status = 'REQUESTED' indexes only unassigned pending jobs.
CREATE INDEX IF NOT EXISTS idx_bookings_requested 
ON bookings (scheduled_start, booking_id) 
INCLUDE (service_id, city_id) 
WHERE status = 'REQUESTED';

-- Queries: W02 (Dispatch assign oldest booking)
-- Type: Partial B-tree Index
-- Column Order: (booking_id)
-- Reason: Instant min(booking_id) scalar lookup for oldest requested booking.
CREATE INDEX IF NOT EXISTS idx_bookings_requested_id 
ON bookings (booking_id) 
WHERE status = 'REQUESTED';

-- ---------------------------------------------------------------------
-- 4. Bookings - Completed Jobs, Quality & Financial Metrics
-- ---------------------------------------------------------------------

-- Queries: R07 (Partner weekly earnings), W04 (Weekly payouts batch generation)
-- Type: Partial Composite Covering B-tree Index
-- Column Order: (pro_id, completed_at)
-- Reason: Equality on pro_id, range on completed_at for status = 'COMPLETED'.
-- INCLUDE (price, discount, tip) avoids visiting heap to sum revenue and tips.
CREATE INDEX IF NOT EXISTS idx_bookings_pro_completed 
ON bookings (pro_id, completed_at) 
INCLUDE (price, discount, tip) 
WHERE status = 'COMPLETED';

-- Queries: R09 (Quality late starts), R19 (City report June jobs), R20 (Daily GMV)
-- Type: Partial Composite Covering B-tree Index
-- Column Order: (scheduled_start)
-- Reason: Evaluates time-windowed COMPLETED bookings. Covers service_id, started_at,
-- pro_id, price, and discount for analytical aggregations without heap access.
CREATE INDEX IF NOT EXISTS idx_bookings_completed_sched 
ON bookings (scheduled_start) 
INCLUDE (service_id, started_at, pro_id, price, discount) 
WHERE status = 'COMPLETED';

-- Queries: R10 (Quality no-show rate per pro)
-- Type: Partial Composite B-tree Index
-- Column Order: (pro_id, status)
-- Reason: Calculates job totals and NO_SHOW counts grouped by pro_id. Excludes
-- unassigned rows (pro_id IS NULL) to maintain concise index coverage.
CREATE INDEX IF NOT EXISTS idx_bookings_pro_status 
ON bookings (pro_id, status) 
WHERE pro_id IS NOT NULL;

-- Queries: R11 (Operations reschedules)
-- Type: Covering B-tree Index
-- Column Order: (created_at)
-- Reason: Range scan on reschedule timestamp. Covering booking_id and requested_by
-- fulfills R11 via Index Only Scan before joining services.
CREATE INDEX IF NOT EXISTS idx_reschedules_created 
ON reschedules (created_at) 
INCLUDE (booking_id, requested_by);

-- Queries: R12 (UC Plus monthly savings)
-- Type: Partial Composite Covering B-tree Index
-- Column Order: (booked_at)
-- Reason: Filter discount > 0 covers only discounted bookings (approx. 20% of data).
-- INCLUDE (discount) enables an Index Only Scan for monthly savings aggregation.
CREATE INDEX IF NOT EXISTS idx_bookings_discount_booked 
ON bookings (booked_at) 
INCLUDE (discount) 
WHERE discount > 0;

-- Queries: R13 (Partner rewards: pros with 0 customer cancellations)
-- Type: Partial B-tree Index
-- Column Order: (pro_id)
-- Reason: Indexes pro_ids associated with CANCELLED_BY_CUSTOMER bookings. Enables
-- instantaneous Anti-Join / NOT EXISTS checks against active professionals.
CREATE INDEX IF NOT EXISTS idx_bookings_cancelled_customer 
ON bookings (pro_id) 
WHERE status = 'CANCELLED_BY_CUSTOMER';

-- Queries: R14 (Demand planning by city, weekday, hour)
-- Type: Composite Covering B-tree Index
-- Column Order: (city_id)
-- Reason: Equality on city_id. Covering service_id and scheduled_start supports
-- the ISO weekday and hour extraction via Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_bookings_city_sched 
ON bookings (city_id) 
INCLUDE (service_id, scheduled_start);

-- Queries: R15 (Quality average pro rating in June)
-- Type: Covering B-tree Index
-- Column Order: (created_at)
-- Reason: Range scan on review creation date. Covering booking_id and rating_for_pro
-- eliminates heap visits on reviews table.
CREATE INDEX IF NOT EXISTS idx_reviews_created 
ON reviews (created_at) 
INCLUDE (booking_id, rating_for_pro);

-- Queries: R16 (Expansion top pincodes in Mumbai)
-- Type: Composite Covering B-tree Index
-- Column Order: (city_id, booked_at)
-- Reason: Equality on city_id, range on booked_at. Covers pincode for Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_bookings_city_booked 
ON bookings (city_id, booked_at) 
INCLUDE (pincode);

-- Queries: R17 (Retention customer frequency)
-- Type: Partial Composite Covering B-tree Index
-- Column Order: (booked_at, customer_id, service_id)
-- Reason: Range on booked_at for COMPLETED bookings, covering customer_id and service_id.
CREATE INDEX IF NOT EXISTS idx_bookings_completed_customer_cat 
ON bookings (booked_at, customer_id, service_id) 
WHERE status = 'COMPLETED';

-- Queries: R18 (Quality reviews complaining about lateness)
-- Type: GIN Trigram Index (pg_trgm)
-- Column: (comment)
-- Reason: ILIKE '%late%' has leading and trailing wildcards, rendering standard B-tree
-- indexes useless. A trigram GIN index extracts 3-character sequences, turning a full table
-- scan of 76k rows into a fast trigram bitmap index scan.
CREATE INDEX IF NOT EXISTS idx_reviews_comment_trgm 
ON reviews USING gin (comment gin_trgm_ops);

-- Queries: R19 (City report last job date per pro)
-- Type: Composite B-tree Index
-- Column Order: (pro_id, completed_at DESC NULLS LAST)
-- Reason: Allows instant lookup of max(completed_at) per pro_id.
CREATE INDEX IF NOT EXISTS idx_bookings_pro_last_job 
ON bookings (pro_id, completed_at DESC NULLS LAST);

-- Queries: R21 (Compliance uncertified services)
-- Type: Partial Composite Covering B-tree Index
-- Column Order: (booking_id)
-- Reason: Covers pro_id and service_id for COMPLETED bookings to verify skills.
CREATE INDEX IF NOT EXISTS idx_bookings_completed_skills 
ON bookings (booking_id) 
INCLUDE (pro_id, service_id) 
WHERE status = 'COMPLETED';

-- Queries: R22 (Support console pagination)
-- Type: Composite Covering B-tree Index
-- Column Order: (booked_at DESC)
-- Reason: Traverses bookings directly in reverse timestamp order, eliminating in-memory
-- sorting and heap fetches when paginating through large offsets.
CREATE INDEX IF NOT EXISTS idx_bookings_booked_at_desc 
ON bookings (booked_at DESC) 
INCLUDE (booking_id, customer_id, service_id, status);

-- Queries: R24 (Finance monthly cancellation fees)
-- Type: Partial Composite Covering B-tree Index
-- Column Order: (scheduled_start)
-- Reason: Partial filter cancellation_fee > 0 indexes only penalized cancellations.
-- Covers cancellation_fee for monthly sum aggregation.
CREATE INDEX IF NOT EXISTS idx_bookings_cancellation_fee 
ON bookings (scheduled_start) 
INCLUDE (cancellation_fee) 
WHERE cancellation_fee > 0;

-- ---------------------------------------------------------------------
-- 5. Payouts & Batch Updates
-- ---------------------------------------------------------------------

-- Queries: R08 (Finance pending payouts)
-- Type: Partial Composite B-tree Index
-- Column Order: (week_start, net_payout DESC)
-- Reason: Filters status = 'PENDING' for a given week_start, sorted by net_payout DESC.
CREATE INDEX IF NOT EXISTS idx_payouts_pending_week 
ON payouts (week_start, net_payout DESC) 
INCLUDE (payout_id, pro_id, jobs) 
WHERE status = 'PENDING';

-- Queries: W04 (Finance weekly payout generation)
-- Type: Partial Composite Covering B-tree Index
-- Column Order: (completed_at, pro_id)
-- Reason: Aggregates completed bookings for payout week range grouped by pro_id.
CREATE INDEX IF NOT EXISTS idx_bookings_completed_payout_week 
ON bookings (completed_at, pro_id) 
INCLUDE (price, discount, tip) 
WHERE status = 'COMPLETED';

-- Queries: W05 (Operations mark unstarted past jobs as NO_SHOW)
-- Type: Partial B-tree Index
-- Column Order: (scheduled_end)
-- Reason: Quickly isolates ASSIGNED bookings that elapsed without starting.
CREATE INDEX IF NOT EXISTS idx_bookings_assigned_noshow 
ON bookings (scheduled_end) 
WHERE status = 'ASSIGNED' AND started_at IS NULL;
