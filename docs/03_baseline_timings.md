# Phase 3: Baseline Query Timings

**Database:** PostgreSQL 18.7 (uc schema, un-tuned baseline — only PK and UNIQUE constraints exist)  
**Method:** 3 runs per query via EXPLAIN (ANALYZE, BUFFERS); write queries (W01–W05) measured inside BEGIN; ... ROLLBACK;.

## 1. Execution Time Summary

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Service menu: active AC Repair services, cheapest first | READ | 4.588 | 0.165 | 0.307 | 1.687 |
| R02: Slot picker: Bengaluru salon professionals free on 3 July 2026 from 11:00 to 12:30 | READ | 94.475 | 43.899 | 41.793 | 60.056 |
| R03: "My bookings": customer 226's upcoming bookings | READ | 17.674 | 16.990 | 16.886 | 17.183 |
| R04: Partner app: professional 425's jobs on 2 July 2026 | READ | 139.097 | 44.501 | 39.209 | 74.269 |
| R05: Dispatch: requested jobs with no professional that start before noon on 2 July 2026 | READ | 19.980 | 21.044 | 19.914 | 20.313 |
| R06: Customer support: look up a customer by mobile number | READ | 0.961 | 0.219 | 0.126 | 0.435 |
| R07: Partner app: professional 425's earnings in the week of 22 June 2026 | READ | 45.868 | 41.369 | 42.511 | 43.249 |
| R08: Finance: payouts still pending for the week starting 22 June 2026 | READ | 7.016 | 3.950 | 5.190 | 5.385 |
| R09: Quality: share of June 2026 jobs that started more than 15 minutes late, per category | READ | 46.651 | 41.247 | 43.855 | 43.918 |
| R10: Quality: no-show rate of professionals with at least 20 assigned jobs | READ | 40.446 | 40.690 | 44.124 | 41.753 |
| R11: Operations: services rescheduled most often in June 2026 | READ | 5.624 | 2.431 | 1.929 | 3.328 |
| R12: UC Plus: total discount given to Plus members per month in 2026 | READ | 43.454 | 42.709 | 44.752 | 43.638 |
| R13: Partner rewards: active professionals who have never had a booking cancelled by a customer | READ | 22.361 | 22.259 | 25.028 | 23.216 |
| R14: Demand planning: Bengaluru bookings by category, weekday and hour of the scheduled slot | READ | 50.413 | 50.173 | 52.808 | 51.131 |
| R15: Quality: professionals whose average rating in June 2026 is below 4.0 (at least 5 reviews) | READ | 43.304 | 33.732 | 29.852 | 35.629 |
| R16: Expansion: top 10 Mumbai pincodes by bookings in June 2026 | READ | 40.715 | 45.258 | 48.358 | 44.777 |
| R17: Retention: customers who booked the same category 3 or more times in 2026 | READ | 45.307 | 41.729 | 44.879 | 43.972 |
| R18: Quality: newest reviews complaining about lateness | READ | 21.777 | 22.189 | 21.643 | 21.870 |
| R19: City report: June 2026 completed jobs and last job date of every active Bengaluru professional | READ | 10994.272 | 11640.652 | 11699.191 | 11444.705 |
| R20: Finance: daily GMV and running total for June 2026 | READ | 50.834 | 39.691 | 141.835 | 77.453 |
| R21: Compliance: completed jobs done by a professional who is not skilled in that service's category | READ | 63.801 | 84.688 | 65.194 | 71.228 |
| R22: Support console: all bookings, newest first, page 4,001 (25 per page) | READ | 92.247 | 108.972 | 97.297 | 99.505 |
| R23: Booking detail page | READ | 0.558 | 0.174 | 0.331 | 0.354 |
| R24: Finance: cancellation fees collected per month in 2026 | READ | 23.932 | 32.529 | 33.570 | 30.010 |
| R25: Capacity: utilisation (booked minutes ÷ available minutes) of Bengaluru professionals, 22–28 June 2026 | READ | 7043.915 | 6399.424 | 6628.081 | 6690.473 |
| W01: Customer app: book an AC service for 3 July 2026, 11:00 | WRITE | 37.185 | 9.528 | 9.506 | 18.740 |
| W02: Dispatch: give the oldest REQUESTED booking to professional 425 | WRITE | 42.105 | 31.910 | 45.184 | 39.733 |
| W03: Partner app: professional 425 finishes their job on 2 July 2026 and gets a ₹50 tip | WRITE | 19.385 | 18.679 | 22.449 | 20.171 |
| W04: Finance: create payouts for the week starting 29 June 2026 from completed jobs | WRITE | 60.491 | 32.720 | 27.482 | 40.231 |
| W05: Operations: assigned jobs whose slot ended before 2 July 2026 without starting become NO_SHOW | WRITE | 20.737 | 19.517 | 21.711 | 20.655 |
| **Total (sum of all 30)** | | **19139.173** | **18933.038** | **19314.995** | **19129.067** |

## 2. Scan Types and Baseline Performance Analysis

- **R01** — **Seq Scan on `services` and `service_categories`:** Fast (1.69 ms) only because both lookup tables are tiny (60 and 10 rows).
- **R02** — **Seq Scan on `bookings`, `professionals`, `pro_skills`, `service_categories` + Index Scan (`pro_availability_pkey`):** Slow (60.06 ms) because checking clashing bookings scans all 150,000 rows without an index on `(pro_id, status, scheduled_start, scheduled_end)`.
- **R03** — **Seq Scan on `bookings` and `services` + Index Scan (`professionals_pkey`):** Slow (17.18 ms) because `bookings(customer_id, scheduled_start)` has no index, forcing a full scan of 150,000 rows.
- **R04** — **Seq Scan on `bookings` and `services`:** Slow (74.27 ms) because `pro_id` is unindexed and wrapping `DATE(b.scheduled_start)` prevents index range scans.
- **R05** — **Seq Scan on `bookings` + Sort:** Slow (20.31 ms) because filtering `status = 'REQUESTED'` scans all 150,000 bookings.
- **R06** — **Index Scan using `customers_phone_key` on `customers`:** Very fast (0.44 ms) because the `UNIQUE` constraint on `customers(phone)` automatically created a B-tree index.
- **R07** — **Seq Scan on `bookings`:** Slow (43.25 ms) because filtering by `pro_id`, `status = 'COMPLETED'`, and `completed_at` scans the whole table.
- **R08** — **Seq Scan on `payouts` and `professionals`:** Scans all 27,015 payouts because `uq_payout_pro_week` leads with `pro_id` rather than `(status, week_start)`.
- **R09** — **Seq Scan on `bookings`, `services`, and `service_categories`:** Scans all 150,000 bookings because `status` and `scheduled_start` are unindexed.
- **R10** — **Seq Scan on `bookings` + HashAggregate:** Full table scan of 150,000 rows to aggregate job counts per `pro_id`.
- **R11** — **Seq Scan on `reschedules` + Index Scan (`bookings_pkey`, `services_pkey`):** Scans all 5,391 reschedule rows because `created_at` is unindexed.
- **R12** — **Seq Scan on `bookings`:** Scans all 150,000 rows due to unindexed `discount > 0` and non-sargable `EXTRACT(YEAR FROM booked_at)`.
- **R13** — **Seq Scan on `professionals` and `bookings`:** Scans all 150,000 bookings and returns **0 rows (wrong result)** because NULL `pro_id` values in `CANCELLED_BY_CUSTOMER` break `NOT IN`.
- **R14** — **Seq Scan on `bookings` and `services`:** Scans all 150,000 rows because `bookings(city_id)` is unindexed.
- **R15** — **Seq Scan on `reviews` and `bookings`:** Scans all 76,539 reviews and 150,000 bookings because `reviews(created_at)` is unindexed.
- **R16** — **Seq Scan on `bookings`:** Scans all 150,000 rows because `(city_id, booked_at)` is unindexed.
- **R17** — **Seq Scan on `bookings` and `services`:** Scans all 150,000 bookings to filter `status = 'COMPLETED'` and `booked_at >= '2026-01-01'`.
- **R18** — **Seq Scan on `reviews` + Top-N Sort:** Scans all 76,539 reviews because leading-wildcard `ILIKE '%late%'` cannot use a standard B-tree index.
- **R19** — **Seq Scan on `professionals` + two correlated Seq Scans on `bookings`:** Extremely slow (11,444.71 ms) because PostgreSQL executes two full sequential scans of 150,000 bookings per active Bengaluru pro.
- **R20** — **Seq Scan on `bookings` + WindowAgg:** Scans all 150,000 rows because `scheduled_start::date` is non-sargable and `status` is unindexed.
- **R21** — **Seq Scan on `bookings`, `services`, and `pro_skills`:** Scans all 150,000 bookings to check skill certification anti-joins.
- **R22** — **Seq Scan on `bookings` + Sort:** Slow (99.51 ms) because sorting 150,000 unindexed rows by `booked_at DESC` and skipping `OFFSET 100000` discards 100,000 rows.
- **R23** — **Index Scan using `bookings_pkey` on `bookings` + Seq Scan on `services`:** Very fast (0.35 ms) single-row lookup via the primary key index.
- **R24** — **Seq Scan on `bookings`:** Scans all 150,000 rows because `cancellation_fee > 0` and `scheduled_start` have no index.
- **R25** — **Index Scan (`professionals_pkey`) + Seq Scan on `pro_availability` + correlated Seq Scan on `bookings`:** Very slow (6,690.47 ms) because the correlated subquery scans 150,000 bookings for each Bengaluru pro.
- **W01** — **Insert on `bookings` (no scan):** Single-row `INSERT` validating PK and FK constraints.
- **W02** — **Index Scan using `bookings_pkey` on `bookings` + Update:** Scans `bookings_pkey` in ID order until hitting the first `status = 'REQUESTED'` row (39.73 ms).
- **W03** — **Seq Scan on `bookings` + Update:** Slow (20.17 ms) for a single-row partner update because `(pro_id, status, scheduled_start)` is unindexed.
- **W04** — **Seq Scan on `bookings` + HashAggregate + Insert on `payouts`:** Scans all 150,000 bookings because `(status, completed_at)` is unindexed.
- **W05** — **Seq Scan on `bookings` + Update:** Scans all 150,000 bookings because `(status, scheduled_end)` is unindexed.