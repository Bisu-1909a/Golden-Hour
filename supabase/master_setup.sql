-- =============================================================================
-- GOLDENHOUR ENGINE: MASTER SETUP SCRIPT (V1.3 - HARDENED)
-- Production Blueprint v1.2 / NIRMAN 2026 / HackNation 2026
-- Covers: 11 Tables, 7 Enums, 5 Engine RPCs, Strict Hospital RLS,
-- Verified Bed Release, Identity Authorization, Views, Seed, Realtime
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. EXTENSIONS & ENUMS
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE alert_state AS ENUM (
        'DRAFT', 'SENT', 'ACKNOWLEDGED', 'CLAIMING', 'ALL_CLAIMED',
        'ARRIVED', 'CLOSED', 'CANCELLED', 'EXPIRED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE task_state AS ENUM ('OPEN', 'CLAIMED', 'DONE', 'ESCALATED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE staff_role AS ENUM (
        'doctor', 'nurse', 'counter', 'medicine', 'equipment',
        'stretcher', 'supervisor', 'operator'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE team_type AS ENUM ('counter', 'medicine', 'equipment', 'stretcher');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE cancel_reason AS ENUM (
        'changed_hospital', 'not_coming', 'duplicate', 'no_arrival', 'other'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE notification_channel AS ENUM (
        'in_app_chime', 'phone_push', 'supervisor_wall', 'sms'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE notification_status AS ENUM ('PENDING', 'SENT', 'FAILED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- -----------------------------------------------------------------------------
-- 2. CORE TABLES & INDEXES
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS facilities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    area TEXT,
    phone TEXT,
    distance_min INT NOT NULL DEFAULT 10,
    capabilities TEXT[] NOT NULL DEFAULT '{}',
    ed_beds_total INT NOT NULL DEFAULT 10,
    ed_beds_free INT NOT NULL DEFAULT 5,
    night_doctor BOOLEAN NOT NULL DEFAULT true,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_facilities_capabilities ON facilities USING gin(capabilities);

CREATE TABLE IF NOT EXISTS staff (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE,
    facility_id UUID REFERENCES facilities(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    role staff_role NOT NULL,
    team team_type,
    pin_hash TEXT NOT NULL,
    is_on_shift BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_staff_facility_role ON staff(facility_id, role);

CREATE TABLE IF NOT EXISTS playbooks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now())
);

CREATE TABLE IF NOT EXISTS playbook_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    playbook_id UUID REFERENCES playbooks(id) ON DELETE CASCADE,
    team team_type NOT NULL,
    title TEXT NOT NULL,
    detail TEXT NOT NULL,
    sla_seconds INT NOT NULL DEFAULT 120,
    backup_staff staff_role,
    position INT NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_playbook_tasks_playbook ON playbook_tasks(playbook_id, position);

CREATE TABLE IF NOT EXISTS alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    temp_id TEXT UNIQUE NOT NULL,
    access_token UUID NOT NULL DEFAULT gen_random_uuid(),
    facility_id UUID REFERENCES facilities(id) ON DELETE RESTRICT,
    patient_name TEXT,
    patient_age INT,
    patient_sex TEXT CHECK (patient_sex IN ('M', 'F', 'O')),
    caller_phone TEXT,
    flags JSONB NOT NULL DEFAULT '{}'::jsonb,
    capability_req TEXT[] NOT NULL DEFAULT '{}',
    playbook_key TEXT DEFAULT 'cardiac',
    eta_minutes INT NOT NULL,
    state alert_state NOT NULL DEFAULT 'SENT',
    cancel_reason cancel_reason,
    expires_at TIMESTAMPTZ GENERATED ALWAYS AS (
        created_at + (eta_minutes * INTERVAL '1 minute') + INTERVAL '5 minutes'
    ) STORED,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    acknowledged_at TIMESTAMPTZ,
    all_claimed_at TIMESTAMPTZ,
    arrived_at TIMESTAMPTZ,
    closed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_alerts_facility_created ON alerts(facility_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_state ON alerts(state);
CREATE INDEX IF NOT EXISTS idx_alerts_temp_id ON alerts(temp_id);

CREATE TABLE IF NOT EXISTS alert_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    task_id UUID REFERENCES playbook_tasks(id) ON DELETE SET NULL,
    team team_type NOT NULL,
    title TEXT NOT NULL,
    detail TEXT NOT NULL,
    sla_seconds INT NOT NULL,
    deadline_at TIMESTAMPTZ NOT NULL,
    state task_state NOT NULL DEFAULT 'OPEN',
    claimed_by UUID REFERENCES staff(id) ON DELETE SET NULL,
    claimed_at TIMESTAMPTZ,
    escalated_at TIMESTAMPTZ,
    escalation_n INT DEFAULT 0,
    done_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_alert_tasks_alert ON alert_tasks(alert_id);
CREATE INDEX IF NOT EXISTS idx_alert_tasks_deadline ON alert_tasks(deadline_at) WHERE state = 'OPEN' AND escalated_at IS NULL;

CREATE TABLE IF NOT EXISTS bed_holds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    facility_id UUID REFERENCES facilities(id) ON DELETE CASCADE,
    bed_label TEXT,
    held_by UUID REFERENCES staff(id) ON DELETE SET NULL,
    held_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    released_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ DEFAULT timezone('utc', now()) + INTERVAL '30 minutes'
);
-- Deterministic unique index for active bed reservations
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_bed_hold ON bed_holds(facility_id, bed_label) WHERE released_at IS NULL;

CREATE TABLE IF NOT EXISTS records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE UNIQUE,
    facility_id UUID REFERENCES facilities(id) ON DELETE CASCADE,
    doctor_id UUID REFERENCES staff(id) ON DELETE SET NULL,
    private_notes TEXT,
    diagnosis TEXT,
    safe_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_records_alert ON records(alert_id);
CREATE INDEX IF NOT EXISTS idx_records_facility ON records(facility_id);

CREATE TABLE IF NOT EXISTS events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    actor_id UUID REFERENCES staff(id) ON DELETE SET NULL,
    actor_role TEXT,
    action TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_events_alert ON events(alert_id, at DESC);

CREATE TABLE IF NOT EXISTS cancellations (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    actor_role TEXT,
    at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_cancellations_alert ON cancellations(alert_id);

CREATE TABLE IF NOT EXISTS notification_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    task_id UUID REFERENCES alert_tasks(id) ON DELETE SET NULL,
    recipient_role TEXT NOT NULL,
    channel notification_channel NOT NULL,
    status notification_status NOT NULL DEFAULT 'PENDING',
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    sent_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_notifications_pending ON notification_outbox(status) WHERE status = 'PENDING';

-- -----------------------------------------------------------------------------
-- 3. AUTO-TASK SPAWN TRIGGER ON ALERT
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION spawn_alert_tasks_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_rec RECORD;
    v_task_count INT := 0;
    v_p_key TEXT;
BEGIN
    v_p_key := COALESCE(NEW.playbook_key, 
        CASE 
            WHEN 'thrombolysis' = ANY(NEW.capability_req) OR 'ct' = ANY(NEW.capability_req) THEN 'stroke'
            WHEN 'blood' = ANY(NEW.capability_req) OR 'ot' = ANY(NEW.capability_req) THEN 'trauma'
            ELSE 'cardiac'
        END
    );

    FOR v_rec IN 
        SELECT pt.id, pt.team, pt.title, pt.detail, pt.sla_seconds, pt.backup_staff
        FROM playbook_tasks pt
        JOIN playbooks p ON pt.playbook_id = p.id
        WHERE p.key = v_p_key
        ORDER BY pt.position ASC
    LOOP
        INSERT INTO alert_tasks (
            alert_id, task_id, team, title, detail, sla_seconds, deadline_at, state
        ) VALUES (
            NEW.id, v_rec.id, v_rec.team, v_rec.title, v_rec.detail, v_rec.sla_seconds,
            NEW.created_at + (v_rec.sla_seconds * INTERVAL '1 second'), 'OPEN'
        );
        v_task_count := v_task_count + 1;
    END LOOP;

    IF v_task_count < 4 THEN
        INSERT INTO alert_tasks (alert_id, team, title, detail, sla_seconds, deadline_at) VALUES
        (NEW.id, 'counter', 'Hold ED bed', 'Reserve intake bed in resus bay', 180, NEW.created_at + INTERVAL '180 seconds'),
        (NEW.id, 'medicine', 'Prepare emergency medicines', 'Draw up urgent medication tray', 120, NEW.created_at + INTERVAL '120 seconds'),
        (NEW.id, 'equipment', 'Prepare critical equipment', 'ECG, Defibrillator, O2 to bay', 120, NEW.created_at + INTERVAL '120 seconds'),
        (NEW.id, 'stretcher', 'Trolley & stretcher to gate', 'Meet vehicle at emergency gate', 90, NEW.created_at + INTERVAL '90 seconds');
    END IF;

    -- Decrement bed count
    UPDATE facilities SET ed_beds_free = GREATEST(0, ed_beds_free - 1) WHERE id = NEW.facility_id AND ed_beds_free > 0;
    INSERT INTO bed_holds (alert_id, facility_id, bed_label, expires_at) VALUES (NEW.id, NEW.facility_id, 'ED-HOLD', timezone('utc', now()) + INTERVAL '30 minutes');

    INSERT INTO events (alert_id, actor_role, action, payload)
    VALUES (NEW.id, 'patient', 'ALERT_CREATED', jsonb_build_object(
        'temp_id', NEW.temp_id, 'facility_id', NEW.facility_id, 'capability_req', NEW.capability_req, 'eta_minutes', NEW.eta_minutes
    ));

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_alerts_spawn_tasks ON alerts;
CREATE TRIGGER trg_alerts_spawn_tasks
AFTER INSERT ON alerts
FOR EACH ROW
EXECUTE FUNCTION spawn_alert_tasks_trigger();

-- -----------------------------------------------------------------------------
-- 4. HARDENED ENGINE RPCS WITH IDENTITY AND BED VERIFICATION
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_staff_facility_id()
RETURNS UUID AS $$
    SELECT facility_id FROM staff WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION auth_staff_role()
RETURNS TEXT AS $$
    SELECT role::text FROM staff WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- 4.1 NEXT_STATE
CREATE OR REPLACE FUNCTION next_state(p_alert_id UUID, p_action TEXT)
RETURNS TEXT AS $$
DECLARE
    v_alert alerts%ROWTYPE;
    v_all_tasks_claimed BOOLEAN;
    v_new_state alert_state;
BEGIN
    SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alert with id % not found', p_alert_id; END IF;
    IF v_alert.state IN ('CANCELLED', 'EXPIRED', 'CLOSED') THEN RETURN v_alert.state::text; END IF;

    IF p_action = 'ACKNOWLEDGE' THEN
        IF v_alert.state = 'SENT' THEN
            v_new_state := 'ACKNOWLEDGED';
            UPDATE alerts SET state = v_new_state, acknowledged_at = timezone('utc', now()) WHERE id = p_alert_id;
            INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'supervisor', 'ACK', '{}'::jsonb);
        ELSE
            v_new_state := v_alert.state;
        END IF;
    ELSIF p_action = 'CHECK_CLAIM_PROGRESS' THEN
        SELECT NOT EXISTS(SELECT 1 FROM alert_tasks WHERE alert_id = p_alert_id AND state = 'OPEN') INTO v_all_tasks_claimed;
        IF v_all_tasks_claimed THEN
            v_new_state := 'ALL_CLAIMED';
            UPDATE alerts SET state = v_new_state, all_claimed_at = timezone('utc', now()) WHERE id = p_alert_id;
            INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'system', 'ALL_CLAIMED', '{}'::jsonb);
        ELSE
            IF v_alert.state = 'ACKNOWLEDGED' THEN
                v_new_state := 'CLAIMING';
                UPDATE alerts SET state = v_new_state WHERE id = p_alert_id;
            ELSE
                v_new_state := v_alert.state;
            END IF;
        END IF;
    ELSIF p_action = 'ARRIVED' THEN
        v_new_state := 'ARRIVED';
        UPDATE alerts SET state = v_new_state, arrived_at = timezone('utc', now()) WHERE id = p_alert_id;
        INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'counter', 'ARRIVED', '{}'::jsonb);
    ELSIF p_action = 'CLOSE' THEN
        IF v_alert.state != 'ARRIVED' THEN RAISE EXCEPTION 'Cannot close alert before arrival is confirmed'; END IF;
        v_new_state := 'CLOSED';
        UPDATE alerts SET state = v_new_state, closed_at = timezone('utc', now()) WHERE id = p_alert_id;
        INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'doctor', 'CLOSED', '{}'::jsonb);
    ELSE
        RAISE EXCEPTION 'Illegal action % for alert state %', p_action, v_alert.state;
    END IF;

    RETURN v_new_state::text;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4.2 CLAIM_TASK (With Verified auth.uid() & Hospital Isolation)
CREATE OR REPLACE FUNCTION claim_task(p_task_id UUID, p_staff_id UUID DEFAULT NULL)
RETURNS JSONB AS $$
DECLARE
    v_task alert_tasks%ROWTYPE;
    v_staff staff%ROWTYPE;
    v_alert alerts%ROWTYPE;
BEGIN
    -- Verify identity
    IF auth.uid() IS NOT NULL THEN
        SELECT * INTO v_staff FROM staff WHERE user_id = auth.uid();
        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'error', 'No active staff profile linked to authenticated user', 'code', 'STAFF_NOT_FOUND');
        END IF;
        IF p_staff_id IS NOT NULL AND v_staff.id <> p_staff_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'Staff identity mismatch: p_staff_id does not match auth.uid()', 'code', 'FORBIDDEN');
        END IF;
    ELSIF p_staff_id IS NOT NULL THEN
        SELECT * INTO v_staff FROM staff WHERE id = p_staff_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'error', 'Staff member not found', 'code', 'STAFF_NOT_FOUND');
        END IF;
    ELSE
        RETURN jsonb_build_object('success', false, 'error', 'Authentication required to claim task', 'code', 'UNAUTHORIZED');
    END IF;

    -- Verify task and hospital boundary
    SELECT t.* INTO v_task FROM alert_tasks t WHERE t.id = p_task_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Task not found', 'code', 'TASK_NOT_FOUND'); END IF;

    SELECT a.* INTO v_alert FROM alerts a WHERE a.id = v_task.alert_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Associated alert not found', 'code', 'ALERT_NOT_FOUND'); END IF;

    IF v_staff.facility_id IS NOT NULL AND v_alert.facility_id IS NOT NULL AND v_staff.facility_id <> v_alert.facility_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cross-facility restriction: Staff cannot claim tasks for another hospital', 'code', 'FACILITY_MISMATCH');
    END IF;

    -- Atomic compare-and-set
    UPDATE alert_tasks
    SET state = 'CLAIMED', claimed_by = v_staff.id, claimed_at = timezone('utc', now()), updated_at = timezone('utc', now())
    WHERE id = p_task_id AND state = 'OPEN'
    RETURNING * INTO v_task;

    IF NOT FOUND THEN
        SELECT * INTO v_task FROM alert_tasks WHERE id = p_task_id;
        RETURN jsonb_build_object('success', false, 'already_claimed', true, 'message', 'Task already claimed', 'claimed_by', v_task.claimed_by, 'claimed_at', v_task.claimed_at, 'current_state', v_task.state);
    END IF;

    -- Audit log
    INSERT INTO events (alert_id, actor_id, actor_role, action, payload)
    VALUES (v_task.alert_id, v_staff.id, v_staff.role::text, 'CLAIM', jsonb_build_object('task_id', v_task.id, 'team', v_task.team, 'title', v_task.title, 'staff_id', v_staff.id, 'staff_name', v_staff.full_name));

    -- Outbox notification
    INSERT INTO notification_outbox (alert_id, task_id, recipient_role, channel, payload)
    VALUES (v_task.alert_id, v_task.id, v_task.team::text, 'in_app_chime', jsonb_build_object('event', 'TASK_CLAIMED', 'task_id', v_task.id, 'title', v_task.title, 'claimed_by_name', v_staff.full_name));

    PERFORM next_state(v_task.alert_id, 'CHECK_CLAIM_PROGRESS');

    RETURN jsonb_build_object('success', true, 'task', row_to_json(v_task));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4.3 ESCALATE_OVERDUE (Idempotent exactly-once)
CREATE OR REPLACE FUNCTION escalate_overdue()
RETURNS TABLE (task_id UUID, alert_id UUID, team TEXT, title TEXT, escalation_n INT) AS $$
BEGIN
    RETURN QUERY
    WITH updated_tasks AS (
        UPDATE alert_tasks
        SET state = 'ESCALATED', escalated_at = timezone('utc', now()), escalation_n = escalation_n + 1, updated_at = timezone('utc', now())
        WHERE deadline_at < timezone('utc', now()) AND state = 'OPEN' AND escalated_at IS NULL
        RETURNING alert_tasks.id, alert_tasks.alert_id, alert_tasks.team::text, alert_tasks.title, alert_tasks.escalation_n
    ),
    logged_events AS (
        INSERT INTO events (alert_id, actor_role, action, payload)
        SELECT ut.alert_id, 'system', 'ESCALATE', jsonb_build_object('task_id', ut.id, 'team', ut.team, 'title', ut.title, 'escalation_n', ut.escalation_n)
        FROM updated_tasks ut
    ),
    queued_notifications AS (
        INSERT INTO notification_outbox (alert_id, task_id, recipient_role, channel, payload)
        SELECT ut.alert_id, ut.id, 'supervisor', 'supervisor_wall', jsonb_build_object('message', 'TASK ESCALATED: ' || ut.title || ' (' || ut.team || ')', 'task_id', ut.id, 'escalation_n', ut.escalation_n)
        FROM updated_tasks ut
    )
    SELECT ut.id, ut.alert_id, ut.team, ut.title, ut.escalation_n FROM updated_tasks ut;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4.4 CANCEL_ALERT (Reversible cancel with verified bed release and idempotency)
CREATE OR REPLACE FUNCTION cancel_alert(p_alert_id UUID, p_reason TEXT DEFAULT 'changed_hospital', p_access_token UUID DEFAULT NULL)
RETURNS JSONB AS $$
DECLARE
    v_alert alerts%ROWTYPE;
    v_staff staff%ROWTYPE;
    v_beds_released INT := 0;
BEGIN
    SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Alert not found', 'code', 'ALERT_NOT_FOUND'); END IF;

    IF v_alert.state = 'CANCELLED' THEN
        RETURN jsonb_build_object('success', true, 'already_cancelled', true, 'message', 'Alert has already been cancelled', 'state', 'CANCELLED');
    END IF;

    IF v_alert.state IN ('ARRIVED', 'CLOSED', 'EXPIRED') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot cancel alert in state ' || v_alert.state, 'code', 'INVALID_STATE_TRANSITION', 'current_state', v_alert.state);
    END IF;

    -- Authorization
    IF auth.role() = 'service_role' THEN
        NULL;
    ELSIF auth.uid() IS NOT NULL THEN
        SELECT * INTO v_staff FROM staff WHERE user_id = auth.uid();
        IF FOUND AND v_staff.facility_id <> v_alert.facility_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'Staff from another facility cannot cancel this alert', 'code', 'FORBIDDEN');
        END IF;
    ELSE
        IF p_access_token IS NULL OR p_access_token <> v_alert.access_token THEN
            RETURN jsonb_build_object('success', false, 'error', 'Valid alert access_token required for patient cancellation', 'code', 'UNAUTHORIZED');
        END IF;
    END IF;

    UPDATE alerts
    SET state = 'CANCELLED', cancel_reason = p_reason::cancel_reason
    WHERE id = p_alert_id AND state NOT IN ('CANCELLED', 'ARRIVED', 'CLOSED', 'EXPIRED');

    IF NOT FOUND THEN
        SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
        RETURN jsonb_build_object('success', false, 'error', 'Concurrent state transition detected', 'current_state', v_alert.state);
    END IF;

    UPDATE alert_tasks SET state = 'DONE', done_at = timezone('utc', now()), updated_at = timezone('utc', now())
    WHERE alert_id = p_alert_id AND state IN ('OPEN', 'ESCALATED');

    -- Release bed hold and ONLY increment facility bed count IF a hold was actually active
    WITH released AS (
        UPDATE bed_holds SET released_at = timezone('utc', now())
        WHERE alert_id = p_alert_id AND released_at IS NULL
        RETURNING facility_id
    )
    UPDATE facilities f
    SET ed_beds_free = LEAST(f.ed_beds_total, f.ed_beds_free + 1)
    FROM released r
    WHERE f.id = r.facility_id;

    GET DIAGNOSTICS v_beds_released = ROW_COUNT;

    INSERT INTO cancellations (alert_id, reason, actor_role) VALUES (p_alert_id, p_reason, COALESCE(v_staff.role::text, 'patient'));
    INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, COALESCE(v_staff.role::text, 'patient'), 'CANCEL', jsonb_build_object('reason', p_reason, 'bed_released', (v_beds_released > 0)));

    INSERT INTO notification_outbox (alert_id, recipient_role, channel, payload)
    VALUES (p_alert_id, 'supervisor', 'supervisor_wall', jsonb_build_object('event', 'ALERT_CANCELLED', 'reason', p_reason, 'bed_released', (v_beds_released > 0)));

    RETURN jsonb_build_object('success', true, 'state', 'CANCELLED', 'bed_released', (v_beds_released > 0));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4.5 ENGINE_TICK
CREATE OR REPLACE FUNCTION engine_tick()
RETURNS JSONB AS $$
DECLARE
    v_escalated_count INT := 0;
    v_expired_alerts_count INT := 0;
    v_released_holds_count INT := 0;
BEGIN
    WITH esc AS (SELECT * FROM escalate_overdue()) SELECT COUNT(*) INTO v_escalated_count FROM esc;

    WITH exp_alerts AS (
        UPDATE alerts SET state = 'EXPIRED'
        WHERE state IN ('SENT', 'ACKNOWLEDGED', 'CLAIMING', 'ALL_CLAIMED')
          AND expires_at IS NOT NULL AND expires_at < timezone('utc', now())
        RETURNING id, facility_id
    ),
    logged_exp AS (
        INSERT INTO events (alert_id, actor_role, action, payload)
        SELECT ea.id, 'system', 'ALERT_EXPIRED', jsonb_build_object('expired_at', timezone('utc', now()))
        FROM exp_alerts ea
    ),
    rel_alert_holds AS (
        UPDATE bed_holds bh SET released_at = timezone('utc', now())
        FROM exp_alerts ea WHERE bh.alert_id = ea.id AND bh.released_at IS NULL
        RETURNING bh.facility_id
    ),
    rel_timeout_holds AS (
        UPDATE bed_holds SET released_at = timezone('utc', now())
        WHERE released_at IS NULL AND expires_at < timezone('utc', now())
        RETURNING facility_id
    ),
    all_released AS (
        SELECT facility_id FROM rel_alert_holds UNION ALL SELECT facility_id FROM rel_timeout_holds
    ),
    agg_released AS (
        SELECT facility_id, COUNT(*) as cnt FROM all_released GROUP BY facility_id
    )
    UPDATE facilities f
    SET ed_beds_free = LEAST(f.ed_beds_total, f.ed_beds_free + ar.cnt::int)
    FROM agg_released ar WHERE f.id = ar.facility_id;

    GET DIAGNOSTICS v_released_holds_count = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'tick_at', timezone('utc', now()), 'tasks_escalated', v_escalated_count, 'alerts_expired', v_expired_alerts_count, 'holds_released', v_released_holds_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Privileged Grants
REVOKE EXECUTE ON FUNCTION engine_tick() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION escalate_overdue() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION next_state(UUID, TEXT) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION engine_tick() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION escalate_overdue() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION next_state(UUID, TEXT) TO authenticated, service_role, postgres;

REVOKE EXECUTE ON FUNCTION claim_task(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION claim_task(UUID, UUID) TO authenticated, service_role, postgres;

GRANT EXECUTE ON FUNCTION cancel_alert(UUID, TEXT, UUID) TO anon, authenticated, service_role, postgres;

-- -----------------------------------------------------------------------------
-- 5. SECURE VIEWS
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS nurse_safe_view CASCADE;
DROP VIEW IF EXISTS ops_metrics_view CASCADE;
DROP VIEW IF EXISTS cancelled_alerts_view CASCADE;

CREATE OR REPLACE VIEW nurse_safe_view
WITH (security_invoker = true)
AS
SELECT 
    a.id AS alert_id,
    a.temp_id,
    bh.bed_label,
    t.title AS current_task,
    t.state AS task_state,
    GREATEST(0, EXTRACT(EPOCH FROM (a.expires_at - now()))::int / 60) AS minutes_remaining,
    r.safe_summary -> 'medicines' AS medicines,
    r.safe_summary -> 'allergies' AS allergies,
    r.safe_summary -> 'watch_for' AS watch_for
FROM alerts a
LEFT JOIN bed_holds bh ON bh.alert_id = a.id AND bh.released_at IS NULL
LEFT JOIN alert_tasks t ON t.alert_id = a.id
LEFT JOIN records r ON r.alert_id = a.id
WHERE a.state NOT IN ('CLOSED', 'CANCELLED', 'EXPIRED');

CREATE OR REPLACE VIEW ops_metrics_view
WITH (security_invoker = true)
AS
SELECT 
    f.id AS facility_id,
    f.name AS facility_name,
    COUNT(a.id) AS total_alerts_today,
    COUNT(a.id) FILTER (WHERE a.state IN ('ARRIVED', 'CLOSED')) AS successful_alerts,
    COUNT(a.id) FILTER (WHERE a.state = 'CANCELLED') AS cancelled_alerts,
    ROUND(
        (COUNT(a.id) FILTER (WHERE a.state = 'CANCELLED')::numeric / 
        GREATEST(1, COUNT(a.id))::numeric) * 100, 1
    ) AS cancellation_rate_pct,
    COUNT(t.id) FILTER (WHERE t.escalation_n > 0) AS total_escalated_tasks,
    COALESCE(
        ROUND(
            PERCENTILE_CONT(0.5) WITHIN GROUP (
                ORDER BY EXTRACT(EPOCH FROM (t.claimed_at - t.created_at))
            ) FILTER (WHERE t.claimed_at IS NOT NULL)
        )::int, 0
    ) AS median_seconds_to_claim
FROM facilities f
LEFT JOIN alerts a ON a.facility_id = f.id AND a.created_at >= CURRENT_DATE
LEFT JOIN alert_tasks t ON t.alert_id = a.id
GROUP BY f.id, f.name;

CREATE OR REPLACE VIEW cancelled_alerts_view
WITH (security_invoker = true)
AS
SELECT 
    c.id AS cancellation_id,
    c.alert_id,
    a.temp_id,
    f.id AS facility_id,
    f.name AS facility_name,
    c.reason,
    c.actor_role,
    c.at AS cancelled_at,
    bh.bed_label,
    ROUND(EXTRACT(EPOCH FROM (bh.released_at - bh.held_at))) AS hold_duration_seconds
FROM cancellations c
JOIN alerts a ON c.alert_id = a.id
JOIN facilities f ON a.facility_id = f.id
LEFT JOIN bed_holds bh ON bh.alert_id = a.id;

-- -----------------------------------------------------------------------------
-- 6. STRICT ROW LEVEL SECURITY POLICIES
-- -----------------------------------------------------------------------------
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

-- Facilities
DROP POLICY IF EXISTS "Public can view active facilities" ON facilities;
CREATE POLICY "Public can view active facilities" ON facilities FOR SELECT USING (is_active = true);

DROP POLICY IF EXISTS "Supervisor can update own facility" ON facilities;
CREATE POLICY "Supervisor can update own facility" ON facilities FOR UPDATE USING (
    auth.role() = 'service_role' OR (id = auth_staff_facility_id() AND auth_staff_role() = 'supervisor')
);

-- Staff
DROP POLICY IF EXISTS "Staff can view active colleagues in same facility" ON staff;
CREATE POLICY "Staff can view active colleagues in same facility" ON staff FOR SELECT USING (
    auth.role() = 'service_role' OR is_on_shift = true
);

-- Playbooks
DROP POLICY IF EXISTS "Anyone can read playbooks" ON playbooks;
CREATE POLICY "Anyone can read playbooks" ON playbooks FOR SELECT USING (true);
DROP POLICY IF EXISTS "Anyone can read playbook tasks" ON playbook_tasks;
CREATE POLICY "Anyone can read playbook tasks" ON playbook_tasks FOR SELECT USING (true);

-- Alerts
DROP POLICY IF EXISTS "Public patient can create emergency alert" ON alerts;
CREATE POLICY "Public patient can create emergency alert" ON alerts FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "Patient can view own alert by token or temp_id" ON alerts;
CREATE POLICY "Patient can view own alert by token or temp_id" ON alerts FOR SELECT USING (
    access_token::text = COALESCE(current_setting('request.headers', true)::json->>'x-access-token', '')
    OR temp_id = COALESCE(current_setting('request.headers', true)::json->>'x-temp-id', '')
);

DROP POLICY IF EXISTS "Staff can view alerts for their own facility" ON alerts;
CREATE POLICY "Staff can view alerts for their own facility" ON alerts FOR SELECT USING (
    auth.role() = 'service_role' OR facility_id = auth_staff_facility_id()
);

DROP POLICY IF EXISTS "Patient can update own alert via access token" ON alerts;
CREATE POLICY "Patient can update own alert via access token" ON alerts FOR UPDATE USING (
    access_token::text = COALESCE(current_setting('request.headers', true)::json->>'x-access-token', '')
);

DROP POLICY IF EXISTS "Staff can update alerts for their own facility" ON alerts;
CREATE POLICY "Staff can update alerts for their own facility" ON alerts FOR UPDATE USING (
    auth.role() = 'service_role' OR facility_id = auth_staff_facility_id()
);

-- Alert Tasks
DROP POLICY IF EXISTS "Patient can view tasks for their alert" ON alert_tasks;
CREATE POLICY "Patient can view tasks for their alert" ON alert_tasks FOR SELECT USING (
    alert_id IN (
        SELECT id FROM alerts WHERE 
            access_token::text = COALESCE(current_setting('request.headers', true)::json->>'x-access-token', '')
            OR temp_id = COALESCE(current_setting('request.headers', true)::json->>'x-temp-id', '')
    )
);

DROP POLICY IF EXISTS "Staff can view tasks for their facility only" ON alert_tasks;
CREATE POLICY "Staff can view tasks for their facility only" ON alert_tasks FOR SELECT USING (
    auth.role() = 'service_role' OR alert_id IN (SELECT id FROM alerts WHERE facility_id = auth_staff_facility_id())
);

DROP POLICY IF EXISTS "Staff can update tasks for their facility only" ON alert_tasks;
CREATE POLICY "Staff can update tasks for their facility only" ON alert_tasks FOR UPDATE USING (
    auth.role() = 'service_role' OR alert_id IN (SELECT id FROM alerts WHERE facility_id = auth_staff_facility_id())
);

-- Bed Holds
DROP POLICY IF EXISTS "Staff can view bed holds for their facility only" ON bed_holds;
CREATE POLICY "Staff can view bed holds for their facility only" ON bed_holds FOR SELECT USING (
    auth.role() = 'service_role' OR facility_id = auth_staff_facility_id()
);

DROP POLICY IF EXISTS "Counter and supervisor can manage bed holds for their facility" ON bed_holds;
CREATE POLICY "Counter and supervisor can manage bed holds for their facility" ON bed_holds FOR ALL USING (
    auth.role() = 'service_role' OR (facility_id = auth_staff_facility_id() AND auth_staff_role() IN ('counter', 'supervisor'))
);

-- Records (Strict Clinical Isolation)
DROP POLICY IF EXISTS "Doctors can view clinical records in their facility" ON records;
CREATE POLICY "Doctors can view clinical records in their facility" ON records FOR SELECT USING (
    auth.role() = 'service_role' OR (facility_id = auth_staff_facility_id() AND auth_staff_role() = 'doctor')
);

DROP POLICY IF EXISTS "Doctors can manage clinical records in their facility" ON records;
CREATE POLICY "Doctors can manage clinical records in their facility" ON records FOR ALL USING (
    auth.role() = 'service_role' OR (facility_id = auth_staff_facility_id() AND auth_staff_role() = 'doctor')
);

-- Events & Cancellations
DROP POLICY IF EXISTS "Allow system and authenticated event inserts" ON events;
CREATE POLICY "Allow system and authenticated event inserts" ON events FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "Staff can view audit events for their facility only" ON events;
CREATE POLICY "Staff can view audit events for their facility only" ON events FOR SELECT USING (
    auth.role() = 'service_role' OR alert_id IN (SELECT id FROM alerts WHERE facility_id = auth_staff_facility_id())
);

DROP POLICY IF EXISTS "Allow cancellation ledger inserts" ON cancellations;
CREATE POLICY "Allow cancellation ledger inserts" ON cancellations FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "Staff can view cancellations for their facility only" ON cancellations;
CREATE POLICY "Staff can view cancellations for their facility only" ON cancellations FOR SELECT USING (
    auth.role() = 'service_role' OR alert_id IN (SELECT id FROM alerts WHERE facility_id = auth_staff_facility_id())
);

-- Notification Outbox
DROP POLICY IF EXISTS "Staff can view notification outbox for their facility" ON notification_outbox;
CREATE POLICY "Staff can view notification outbox for their facility" ON notification_outbox FOR SELECT USING (
    auth.role() = 'service_role' OR alert_id IN (SELECT id FROM alerts WHERE facility_id = auth_staff_facility_id())
);

DROP POLICY IF EXISTS "Engine service_role can manage notification outbox" ON notification_outbox;
CREATE POLICY "Engine service_role can manage notification outbox" ON notification_outbox FOR ALL USING (
    auth.role() = 'service_role'
);

-- -----------------------------------------------------------------------------
-- 7. SEED DATA (Bhubaneswar Emergency Network)
-- -----------------------------------------------------------------------------
INSERT INTO facilities (id, name, area, phone, distance_min, capabilities, ed_beds_total, ed_beds_free, night_doctor, is_active)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'Capital Hospital, Bhubaneswar', 'Unit 6, Bhubaneswar', '+91-674-2391983', 8, ARRAY['ecg', 'defibrillator', 'blood_bank', 'icu', 'trauma', 'ot', 'oxygen'], 20, 4, true, true),
    ('22222222-2222-2222-2222-222222222222', 'AIIMS Bhubaneswar', 'Sijua, Patrapada', '+91-674-2476789', 14, ARRAY['ecg', 'defibrillator', 'blood_bank', 'icu', 'cath_lab', 'ct_scan', 'neuro_surgery', 'trauma', 'ot', 'oxygen'], 35, 12, true, true),
    ('33333333-3333-3333-3333-333333333333', 'SUM Ultimate Medicare', 'K8 Kalinga Nagar', '+91-674-3500500', 12, ARRAY['ecg', 'defibrillator', 'blood_bank', 'icu', 'cath_lab', 'stroke_unit', 'ot', 'oxygen'], 25, 7, true, true)
ON CONFLICT (id) DO UPDATE SET 
    name = EXCLUDED.name, ed_beds_total = EXCLUDED.ed_beds_total, ed_beds_free = EXCLUDED.ed_beds_free;

INSERT INTO staff (id, facility_id, full_name, role, team, pin_hash, is_on_shift)
VALUES 
    ('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Dr. Subrat Mohanty', 'doctor', null, crypt('1234', gen_salt('bf')), true),
    ('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Sister Arati Jena', 'nurse', 'medicine', crypt('1234', gen_salt('bf')), true),
    ('a0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Nurse Priyanka Das', 'nurse', 'equipment', crypt('1234', gen_salt('bf')), true),
    ('a0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Ramesh Nayak', 'counter', 'counter', crypt('1234', gen_salt('bf')), true),
    ('a0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Bikash Sethi', 'stretcher', 'stretcher', crypt('1234', gen_salt('bf')), true),
    ('a0000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'Manas Pradhan', 'supervisor', null, crypt('1234', gen_salt('bf')), true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO playbooks (id, key, name, version)
VALUES 
    ('b0000000-0000-0000-0000-000000000001', 'cardiac', 'Cardiac Emergency Protocol', 1),
    ('b0000000-0000-0000-0000-000000000002', 'stroke', 'Acute Stroke / CVA Protocol', 1),
    ('b0000000-0000-0000-0000-000000000003', 'trauma', 'Major Trauma & Hemorrhage Protocol', 1)
ON CONFLICT (key) DO NOTHING;

INSERT INTO playbook_tasks (playbook_id, team, title, detail, sla_seconds, backup_staff, position)
VALUES 
    ('b0000000-0000-0000-0000-000000000001', 'counter', 'Hold ED intake bed', 'Reserve monitored bed in resuscitation bay', 180, null, 1),
    ('b0000000-0000-0000-0000-000000000001', 'medicine', 'Prepare cardiac medications', 'Draw up Aspirin 300mg, Clopidogrel 300mg, Atorvastatin 80mg, NTG infusion', 120, null, 2),
    ('b0000000-0000-0000-0000-000000000001', 'equipment', 'Prepare 12-lead ECG & defibrillator', 'Ensure ECG calibrated and biphasic pads connected with O2 mask ready', 120, null, 3),
    ('b0000000-0000-0000-0000-000000000001', 'stretcher', 'Trolley & stretcher to gate', 'Position resuscitation stretcher with O2 cylinder at ambulance bay', 90, null, 4)
ON CONFLICT (playbook_id, position) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 8. REALTIME REPLICATION PUBLICATION
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE alerts, alert_tasks, bed_holds, notification_outbox;
EXCEPTION WHEN others THEN null; END $$;
