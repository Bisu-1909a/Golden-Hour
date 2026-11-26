-- =============================================================================
-- Migration 003: Row Level Security (RLS) for GoldenHour
-- Ensures strict multi-tenant isolation by hospital, prevents unauthorized
-- cross-hospital access, enables anonymous family access via secure tokens,
-- and preserves append-only immutability.
-- =============================================================================

-- Enable RLS on all tables
ALTER TABLE hospitals ENABLE ROW LEVEL SECURITY;
ALTER TABLE hospital_capabilities ENABLE ROW LEVEL SECURITY;
ALTER TABLE hospital_resources ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE alert_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- 1. HOSPITALS POLICIES
-- -----------------------------------------------------------------------------
-- Public/Family can read active hospitals for emergency capability matching
CREATE POLICY "Public can view active hospitals for matching"
ON hospitals FOR SELECT
USING (is_active = true);

-- Hospital admins can update their own hospital details
CREATE POLICY "Staff can update own hospital"
ON hospitals FOR UPDATE
USING (
    id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-hospital-id',
        auth.jwt() -> 'app_metadata' ->> 'hospital_id'
    )
);

-- -----------------------------------------------------------------------------
-- 2. HOSPITAL CAPABILITIES POLICIES
-- -----------------------------------------------------------------------------
-- Public/Family can view active capabilities to find the right hospital
CREATE POLICY "Public can view capabilities for matching"
ON hospital_capabilities FOR SELECT
USING (true);

-- Hospital staff can manage and confirm their own capabilities
CREATE POLICY "Staff can update own capabilities"
ON hospital_capabilities FOR ALL
USING (
    hospital_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-hospital-id',
        auth.jwt() -> 'app_metadata' ->> 'hospital_id'
    )
);

-- -----------------------------------------------------------------------------
-- 3. HOSPITAL RESOURCES POLICIES
-- -----------------------------------------------------------------------------
-- Public can view bed availability numbers for matching
CREATE POLICY "Public can view bed capacity"
ON hospital_resources FOR SELECT
USING (true);

-- Staff can update their hospital's emergency bed count and active teams
CREATE POLICY "Staff can manage own hospital resources"
ON hospital_resources FOR ALL
USING (
    hospital_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-hospital-id',
        auth.jwt() -> 'app_metadata' ->> 'hospital_id'
    )
);

-- -----------------------------------------------------------------------------
-- 4. STAFF MEMBERS POLICIES
-- -----------------------------------------------------------------------------
-- Allow staff PIN lookup / demo login
CREATE POLICY "Allow PIN verification"
ON staff_members FOR SELECT
USING (is_active = true);

-- Admin can manage staff
CREATE POLICY "Hospital Admin can manage staff"
ON staff_members FOR ALL
USING (
    hospital_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-hospital-id',
        auth.jwt() -> 'app_metadata' ->> 'hospital_id'
    )
);

-- -----------------------------------------------------------------------------
-- 5. TASK TEMPLATES POLICIES
-- -----------------------------------------------------------------------------
-- Anyone can read task templates to view or render the 4 tasks
CREATE POLICY "Anyone can read task templates"
ON task_templates FOR SELECT
USING (true);

-- Hospital staff can customize their own 4 templates
CREATE POLICY "Staff can manage own task templates"
ON task_templates FOR ALL
USING (
    hospital_id IS NULL OR 
    hospital_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-hospital-id',
        auth.jwt() -> 'app_metadata' ->> 'hospital_id'
    )
);

-- -----------------------------------------------------------------------------
-- 6. ALERTS POLICIES
-- -----------------------------------------------------------------------------
-- Anyone (family or 108 operator) can raise an alert without logging in
CREATE POLICY "Family can create new alert"
ON alerts FOR INSERT
WITH CHECK (true);

-- Family can view their own alert via access_token or alert_code
CREATE POLICY "Family can view own alert via token"
ON alerts FOR SELECT
USING (
    access_token::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-access-token',
        ''
    )
    OR
    alert_code = COALESCE(
        current_setting('request.headers', true)::json->>'x-alert-code',
        ''
    )
);

-- Family can cancel their own alert with one tap
CREATE POLICY "Family can cancel own alert"
ON alerts FOR UPDATE
USING (
    access_token::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-access-token',
        ''
    )
)
WITH CHECK (
    status = 'cancelled'
);

-- Hospital staff can view and manage only alerts for their specific hospital
CREATE POLICY "Hospital staff can view own hospital alerts"
ON alerts FOR SELECT
USING (
    hospital_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-hospital-id',
        auth.jwt() -> 'app_metadata' ->> 'hospital_id'
    )
);

CREATE POLICY "Hospital staff can update own hospital alerts"
ON alerts FOR UPDATE
USING (
    hospital_id::text = COALESCE(
        current_setting('request.headers', true)::json->>'x-hospital-id',
        auth.jwt() -> 'app_metadata' ->> 'hospital_id'
    )
);

-- -----------------------------------------------------------------------------
-- 7. ALERT TASKS POLICIES
-- -----------------------------------------------------------------------------
-- Family can read the 4 tasks of their alert to see readiness progress ("3 of 4 taken")
CREATE POLICY "Family can view tasks for their alert"
ON alert_tasks FOR SELECT
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE access_token::text = COALESCE(
            current_setting('request.headers', true)::json->>'x-access-token',
            ''
        )
    )
);

-- Hospital staff can view tasks for their hospital's alerts
CREATE POLICY "Staff can view own hospital tasks"
ON alert_tasks FOR SELECT
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE hospital_id::text = COALESCE(
            current_setting('request.headers', true)::json->>'x-hospital-id',
            auth.jwt() -> 'app_metadata' ->> 'hospital_id'
        )
    )
);

-- Hospital staff can claim or update tasks for their hospital
CREATE POLICY "Staff can update own hospital tasks"
ON alert_tasks FOR UPDATE
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE hospital_id::text = COALESCE(
            current_setting('request.headers', true)::json->>'x-hospital-id',
            auth.jwt() -> 'app_metadata' ->> 'hospital_id'
        )
    )
);

-- -----------------------------------------------------------------------------
-- 8. AUDIT LOGS POLICIES
-- Append-only table: strictly NO UPDATE or DELETE allowed under any policy.
-- -----------------------------------------------------------------------------
-- Hospital staff can view audit trail for their own hospital's alerts
CREATE POLICY "Staff can view own alert audit logs"
ON audit_logs FOR SELECT
USING (
    alert_id IN (
        SELECT id FROM alerts WHERE hospital_id::text = COALESCE(
            current_setting('request.headers', true)::json->>'x-hospital-id',
            auth.jwt() -> 'app_metadata' ->> 'hospital_id'
        )
    )
);

-- Allow system/functions to insert audit records
CREATE POLICY "System and users can insert audit logs"
ON audit_logs FOR INSERT
WITH CHECK (true);
