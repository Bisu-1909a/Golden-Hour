-- RLS Policies for Alerts, Tasks, Beds, Records, Events, Facilities, Staff
-- GoldenHour Blueprint §7.4 / NIRMAN 2026

-- Enable RLS across all tables
ALTER TABLE facilities ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE playbooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE playbook_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE alert_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE bed_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE records ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE cancellations ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_outbox ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- 1. FACILITIES
-- -----------------------------------------------------------------------------
CREATE POLICY "Public can view active facilities"
ON facilities FOR SELECT
USING (is_active = true);

CREATE POLICY "Supervisor can update facility"
ON facilities FOR UPDATE
USING (
    id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-facility-id',
        auth.jwt() -> 'app_metadata' ->> 'facility_id'
    )
);

-- -----------------------------------------------------------------------------
-- 2. STAFF
-- -----------------------------------------------------------------------------
CREATE POLICY "Allow staff PIN and profile lookup"
ON staff FOR SELECT
USING (is_on_shift = true);

-- -----------------------------------------------------------------------------
-- 3. PLAYBOOKS & PLAYBOOK TASKS
-- -----------------------------------------------------------------------------
CREATE POLICY "Anyone can read playbooks"
ON playbooks FOR SELECT USING (true);

CREATE POLICY "Anyone can read playbook tasks"
ON playbook_tasks FOR SELECT USING (true);

-- -----------------------------------------------------------------------------
-- 4. ALERTS
-- -----------------------------------------------------------------------------
-- Patient can create alert without login
CREATE POLICY "Public can create alert"
ON alerts FOR INSERT
WITH CHECK (true);

-- Patient can select their own alert via temp_id or access_token
CREATE POLICY "Patient can view own alert"
ON alerts FOR SELECT
USING (
    access_token::text = COALESCE(current_setting('request.headers', true)::json->>'x-access-token', '')
    OR
    temp_id = COALESCE(current_setting('request.headers', true)::json->>'x-temp-id', '')
    OR
    facility_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-facility-id',
        auth.jwt() -> 'app_metadata' ->> 'facility_id'
    )
);

-- Patient can cancel their own alert
CREATE POLICY "Patient can cancel own alert"
ON alerts FOR UPDATE
USING (
    access_token::text = COALESCE(current_setting('request.headers', true)::json->>'x-access-token', '')
    OR
    facility_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-facility-id',
        auth.jwt() -> 'app_metadata' ->> 'facility_id'
    )
);

-- -----------------------------------------------------------------------------
-- 5. ALERT TASKS
-- -----------------------------------------------------------------------------
CREATE POLICY "Staff can view tasks for their facility"
ON alert_tasks FOR SELECT
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE 
            facility_id::text = COALESCE(
                current_setting('request.headers', true)::json->>'x-facility-id',
                auth.jwt() -> 'app_metadata' ->> 'facility_id'
            )
            OR access_token::text = COALESCE(current_setting('request.headers', true)::json->>'x-access-token', '')
    )
);

CREATE POLICY "Staff can claim tasks for their facility"
ON alert_tasks FOR UPDATE
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE 
            facility_id::text = COALESCE(
                current_setting('request.headers', true)::json->>'x-facility-id',
                auth.jwt() -> 'app_metadata' ->> 'facility_id'
            )
    )
);

-- -----------------------------------------------------------------------------
-- 6. BED HOLDS
-- -----------------------------------------------------------------------------
CREATE POLICY "Counter and supervisor can view bed holds"
ON bed_holds FOR SELECT
USING (
    facility_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-facility-id',
        auth.jwt() -> 'app_metadata' ->> 'facility_id'
    )
);

CREATE POLICY "Counter and supervisor can manage bed holds"
ON bed_holds FOR ALL
USING (
    facility_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-facility-id',
        auth.jwt() -> 'app_metadata' ->> 'facility_id'
    )
);

-- -----------------------------------------------------------------------------
-- 7. RECORDS (Clinical)
-- -----------------------------------------------------------------------------
-- Doctor: full access. Nurse: completely denied at table level (reads nurse_safe_view).
CREATE POLICY "Doctor can view and write records"
ON records FOR ALL
USING (
    facility_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-facility-id',
        auth.jwt() -> 'app_metadata' ->> 'facility_id'
    )
);

-- -----------------------------------------------------------------------------
-- 8. EVENTS & CANCELLATIONS (Append-only)
-- -----------------------------------------------------------------------------
CREATE POLICY "Allow authenticated and system event inserts"
ON events FOR INSERT WITH CHECK (true);

CREATE POLICY "Staff can view events for their facility"
ON events FOR SELECT
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE 
            facility_id::text = COALESCE(
                current_setting('request.headers', true)::json->>'x-facility-id',
                auth.jwt() -> 'app_metadata' ->> 'facility_id'
            )
    )
);

CREATE POLICY "Allow cancellation inserts"
ON cancellations FOR INSERT WITH CHECK (true);

CREATE POLICY "Staff can view cancellations for their facility"
ON cancellations FOR SELECT
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE 
            facility_id::text = COALESCE(
                current_setting('request.headers', true)::json->>'x-facility-id',
                auth.jwt() -> 'app_metadata' ->> 'facility_id'
            )
    )
);

-- -----------------------------------------------------------------------------
-- 9. NOTIFICATION OUTBOX
-- -----------------------------------------------------------------------------
CREATE POLICY "Allow outbox inserts and updates by system"
ON notification_outbox FOR ALL
USING (true);
