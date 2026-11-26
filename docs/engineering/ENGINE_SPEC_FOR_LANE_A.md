# GoldenHour: Database Architecture & Engine Specification
**Prepared by Member E (Data & Platform) for Member A (Technical Lead / Engine)**
**Conforms to Blueprint v1.2 & Handbook v2.0**

This document delivers the complete specification answering all 9 alignment requests from the Technical Lead.

---

### 1. Final Database Schema for All Engine Tables

The schema is divided into 11 timestamped migration files under `supabase/migrations/`:
1. `facilities`: Facility registry, coordinates, bed capacity (`ed_beds_total`, `ed_beds_free`), and capabilities array.
2. `staff`: Staff authentication profile (`user_id`), facility linkage, operational `role`, `team`, and `pin_hash`.
3. `playbooks`: Standard clinical emergency protocols (`cardiac`, `stroke`, `trauma`).
4. `playbook_tasks`: Protocol task templates with team assignment (`counter`, `medicine`, `equipment`, `stretcher`) and SLA.
5. `alerts`: Main emergency alert entity, tracking `temp_id`, `state`, timestamps, capability requirements, and expiry.
6. `alert_tasks`: Active task instances generated per alert, storing `sla_seconds`, `deadline_at`, `state`, `claimed_by`, and `escalated_at`.
7. `bed_holds`: Ephemeral 30-minute bed reservations, with partial unique index to prevent duplicate holds.
8. `records`: Minimum viable clinical record. Doctor writes diagnosis & notes; nurse reads only `safe_summary`.
9. `events`: Append-only immutable task history and audit trail (`trg_events_immutable` strictly blocks UPDATE/DELETE).
10. `cancellations`: Waste ledger recording reason and duration for every cancelled/diverted alert.
11. `notification_outbox`: Real-time notification queue for dispatching in-app chimes, wall banners, and SMS/push.

---

### 2. `task_status` Enum Values & Lifecycle States

* **`task_state` enum values**:
  * `'OPEN'`: Initial state when alert is generated.
  * `'CLAIMED'`: Claimed by an authenticated staff member.
  * `'DONE'`: Task action completed.
  * `'ESCALATED'`: SLA elapsed without claim (`escalated_at IS NOT NULL`).
* **`alert_state` enum values**:
  * `'DRAFT'` $\to$ `'SENT'` $\to$ `'ACKNOWLEDGED'` $\to$ `'CLAIMING'` $\to$ `'ALL_CLAIMED'` $\to$ `'ARRIVED'` $\to$ `'CLOSED'`.
  * Terminal edge states: `'CANCELLED'` (one-tap cancel), `'EXPIRED'` (ETA + 5 min no-show).

---

### 3. Table Relationships and Foreign Keys

* `facilities (1) ── (N) staff` (`facility_id REFERENCES facilities(id) ON DELETE CASCADE`)
* `facilities (1) ── (N) alerts` (`facility_id REFERENCES facilities(id) ON DELETE RESTRICT`)
* `facilities (1) ── (N) bed_holds` (`facility_id REFERENCES facilities(id) ON DELETE CASCADE`)
* `playbooks (1) ── (N) playbook_tasks` (`playbook_id REFERENCES playbooks(id) ON DELETE CASCADE`)
* `alerts (1) ── (N) alert_tasks` (`alert_id REFERENCES alerts(id) ON DELETE CASCADE`)
* `playbook_tasks (1) ── (N) alert_tasks` (`task_id REFERENCES playbook_tasks(id) ON DELETE SET NULL`)
* `staff (1) ── (N) alert_tasks` (`claimed_by REFERENCES staff(id) ON DELETE SET NULL`)
* `alerts (1) ── (1) records` (`alert_id REFERENCES alerts(id) ON DELETE CASCADE UNIQUE`)
* `alerts (1) ── (N) events` (`alert_id REFERENCES alerts(id) ON DELETE CASCADE`)
* `alerts (1) ── (N) notification_outbox` (`alert_id REFERENCES alerts(id) ON DELETE CASCADE`)

---

### 4. RLS Policies and Permissions Matrix

Located in `supabase/policies/all-policies.sql` and `supabase/policies/rls-matrix.md`:
* **`alerts`**:
  * Public/Patient: Can `INSERT` without auth; can `SELECT` and `UPDATE` (cancel) only own alert via `access_token` or `temp_id`.
  * Staff: Can `SELECT` and `UPDATE` alerts where `facility_id = current_user_facility()`.
* **`alert_tasks`**:
  * Staff: Can `SELECT` and `UPDATE` (claim) tasks belonging to their facility's alerts.
* **`records` vs `nurse_safe_view`**:
  * Base table `records` is restricted to `doctor` role and `service_role`.
  * `nurse_safe_view` is granted to the `nurse` role, omitting `diagnosis`, `private_notes`, and patient identity.
* **`events` & `cancellations`**:
  * Insert allowed for all authenticated and system operations.
  * Append-only: DB trigger blocks any `UPDATE` or `DELETE`.

---

### 5. `engine_owner` Role Setup & Alternatives

* **Recommended Production Pattern**: Supabase `service_role`.
  * The background engine tick endpoint (`/api/engine/tick`) and Edge Functions execute under the `service_role` key (bypassing RLS with full system privileges).
  * Route is guarded by `ENGINE_SHARED_SECRET` in request headers.
* **Database Function Alternative**: All 5 engine functions (`next_state`, `claim_task`, `escalate_overdue`, `cancel_alert`, `engine_tick`) are declared as `SECURITY DEFINER` in PostgreSQL, allowing API routes to invoke them reliably while maintaining row isolation.

---

### 6. How Task Deadlines & SLAs Are Stored

* Configured in `playbook_tasks`: `sla_seconds INT NOT NULL` (e.g., Stretcher: 90s, Medicine: 120s, Equipment: 120s, Bed: 180s).
* Stored on `alert_tasks`:
  * `sla_seconds INT NOT NULL`
  * `deadline_at TIMESTAMPTZ NOT NULL`: Calculated on alert creation as `created_at + (sla_seconds * INTERVAL '1 second')`.
  * `escalated_at TIMESTAMPTZ`: Set to `timezone('utc', now())` upon SLA breach.
  * `escalation_n INT DEFAULT 0`: Counter incremented when escalated.
* **Idempotency Guarantee**:
  `UPDATE alert_tasks SET state = 'ESCALATED', escalated_at = now() WHERE deadline_at < now() AND state = 'OPEN' AND escalated_at IS NULL;`
  Calling `engine_tick()` 10 times in one second produces exactly one escalation row.

---

### 7. Notification Outbox and Task History Table Structure

#### Task History & Audit Trail (`events` table):
```sql
CREATE TABLE events (
    id BIGSERIAL PRIMARY KEY,
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    actor_id UUID,
    actor_role TEXT,
    action TEXT NOT NULL,       -- ALERT_CREATED, ACK, CLAIM, ESCALATE, CANCEL
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
```

#### Notification Outbox (`notification_outbox` table):
```sql
CREATE TABLE notification_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE NOT NULL,
    task_id UUID REFERENCES alert_tasks(id) ON DELETE CASCADE,
    recipient_role TEXT NOT NULL,
    channel TEXT NOT NULL CHECK (channel IN ('in_app_chime', 'phone_push', 'supervisor_wall', 'sms')),
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'SENT', 'FAILED')),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    sent_at TIMESTAMPTZ
);
```

---

### 8. Generated Database Types

* Strongly-typed definitions generated and committed in:
  * `src/types/database.ts` (consumed by Next.js app)
  * `supabase/types/db.generated.ts` (consumed by Supabase scripts and tests)
* Provides full interfaces for all tables, row inserts, updates, views (`nurse_safe_view`, `ops_metrics_view`), and RPC functions (`next_state`, `claim_task`, `engine_tick`, `cancel_alert`).

---

### 9. Timeline for Sharing the Schema

* **Status**: Complete & Ready Now.
* **Target Delivery**: Delivered in Branch `e-platform` ahead of Block 1 deadline (T+0:20).
* **Next Action**: Submitted via Pull Request from `e-platform` into `main` for Member A review and merge.
