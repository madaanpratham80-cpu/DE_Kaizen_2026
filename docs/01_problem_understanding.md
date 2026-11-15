# Phase 1: Problem Understanding

Urban Company connects customers who need home services (like AC repair, cleaning, or salon work) with trained professionals. Right now, the database was built in a hurry without proper keys, constraints, or indexes. Because of this, the app lags for users and internal teams cannot run their daily reports properly.

## 1. Breakdown of Problems (P1 – P8)

| Problem | What the business actually needs (in simple terms) | Stakeholders Affected | Queries | Classification |
| :--- | :--- | :--- | :--- | :--- |

| **P1** | **Fast service menu and slot booking:** When a customer opens the app to pick a service and time slot, the app needs to quickly load active services by price, find active professionals in that city who have the right skill, are working at that time, and don't already have another job booked in that slot, and then save the booking immediately. | Customer, Service professional (partner) | `R01`, `R02`, `W01` | **Customer-facing / real-time** |

| **P2** | **Quick booking lookups for customers and support:** Customers checking their "My Bookings" page or opening a single booking's details shouldn't have to wait. Also, customer support needs to quickly search customers by phone number and flip through pages of old bookings without the screen freezing. | Customer, Support | `R03`, `R06`, `R22`, `R23` | **Customer-facing / real-time** (`R03`, `R06`, `R23`)<br>**Reporting / analytics** (`R22` support console) |

| **P3** | **Smooth partner app for pros in the field:** Professionals use their app on mobile data while traveling to homes. They need to quickly check their jobs for the day, see how much money and tips they earned that week, and mark a job as completed without the app hanging. | Service professional (partner) | `R04`, `R07`, `W03` | **Customer-facing / real-time** |

| **P4** | **Fast dispatch tracking for unassigned jobs:** The dispatch team needs to quickly spot requested bookings that haven't been given to a professional yet and are about to start soon. They also need to quickly assign the oldest pending booking to a pro and update old unstarted bookings to `NO_SHOW`. | Dispatch/operations, Customer, Service professional (partner) | `R05`, `W02`, `W05` | **Customer-facing / real-time** (`R05`, `W02`)<br>**Reporting / analytics** (`W05` ops update) |

| **P5** | **Fix the empty partner rewards list:** The team wants a list of active professionals who have zero customer cancellations so they can reward them. Right now the query gives 0 results every time because some bookings are cancelled by customers before any pro is assigned (`pro_id` is `NULL`), which breaks the `NOT IN` condition in SQL. | Service professional (partner), Quality team, Dispatch/operations | `R13` | **Reporting / analytics** |

| **P6** | **Quality and compliance checks that don't time out:** The quality team needs working reports to check how often jobs start more than 15 minutes late, which pros have high no-show rates or low ratings (under 4.0), recent reviews complaining about being "late", and cases where a pro did a job they weren't certified for. | Quality team, Service professional (partner) | `R09`, `R10`, `R15`, `R18`, `R21` | **Reporting / analytics** |

| **P7** | **Faster finance, payout, and UC Plus reports:** The finance and UC Plus teams need to calculate weekly payouts for pros, check which payouts are still pending, track total discounts given to UC Plus members, add up monthly cancellation fees, and view daily revenue (GMV) without waiting forever. | Finance (payouts), UC Plus team, Service professional (partner) | `R08`, `R12`, `R20`, `R24`, `W04` | **Reporting / analytics** |

| **P8** | **City expansion and operations planning for 20x growth:** Operations and expansion teams need reports on frequently rescheduled services, busy hours/weekdays in a city, top pincodes by booking count, repeat customers, pro workload/activity, and how much of a pro's available time is actually booked. These must still work when bookings grow 20x next year. | Dispatch/operations, City expansion | `R11`, `R14`, `R16`, `R17`, `R19`, `R25` | **Reporting / analytics** |

---

## 2. Why the Classification Matters (Performance Targets)

* **Customer-facing / real-time queries (`R01–R07`, `R23`, `W01–W03`):** Someone is waiting on an app screen for these to finish, so they must run in **under 5 ms** even on the large dataset.

* **Reporting / analytics & internal tools (`R08–R22`, `R24–R25`, `W04–W05`):** These run in internal dashboards or background jobs. Interactive ops tools need to finish in **under 250 ms**, weekly payout batch creation (`W04`) in **under 1,000 ms**, and heavy analytical reports in **under 5,000 ms**.

---

## 3. Assumptions Made

1. **All times are in IST (`+05:30`):** Every timestamp in the CSV files uses Indian Standard Time, so date checks and working hours are compared in `Asia/Kolkata` time.

2. **When columns are allowed to be NULL:** When a customer first creates a booking (`REQUESTED`), no professional is assigned yet, so `pro_id`, `started_at`, and `completed_at` are empty (`NULL`). If a customer cancels before a pro is assigned, `pro_id` stays `NULL`.

3. **Tips and cancellation fees:** A customer can only leave a tip if the job is `COMPLETED`, and a cancellation fee is only charged when the status is `CANCELLED_BY_CUSTOMER`.

4. **Weekly payouts:** Professionals are paid once a week for their completed jobs, and every payout week starts on a Monday. Commission is 20% of `(price - discount)`, while the professional keeps 100% of the tip.