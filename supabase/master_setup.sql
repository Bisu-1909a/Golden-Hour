-- =============================================================================
-- GOLDENHOUR: ALL-IN-ONE MASTER SETUP SCRIPT FOR SUPABASE
-- Run this in the Supabase SQL Editor to provision the complete database:
-- Extensions, Enums, Tables, Indexes, Triggers, Engine Functions, Views,
-- RLS Policies, Realtime Publication, and Seed Data in a single run.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. EXTENSIONS & ENUMS
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";

DO $$ BEGIN
    CREATE TYPE alert_state AS ENUM ('DRAFT', 'SENT', 'ACKNOWLEDGED', 'CLAIMING', 'ALL_CLAIMED', 'ARRIVED', 'CLOSED', 'CANCELLED', 'EXPIRED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE task_state AS ENUM ('OPEN', 'CLAIMED', 'DONE', 'ESCALATED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE staff_role AS ENUM ('doctor', 'nurse', 'counter', 'medicine', 'equipment', 'stretcher', 'supervisor', 'operator');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE team_type AS ENUM ('counter', 'medicine', 'equipment', 'stretcher');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE cancel_reason_enum AS ENUM ('changed_hospital', 'not_coming', 'duplicate', 'no_arrival', 'other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE notification_channel AS ENUM ('in_app_chime', 'phone_push', 'supervisor_wall', 'sms');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE notification_status AS ENUM ('PENDING', 'SENT', 'FAILED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- 2. TABLES & INDEXES
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS facilities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    area TEXT,
    phone TEXT,
    distance_min INT DEFAULT 8,
    capabilities TEXT[] NOT NULL DEFAULT '{}',
    ed_beds_total INT DEFAULT 10 CHECK (ed_beds_total >= 0),
    ed_beds_free INT DEFAULT 5 CHECK (ed_beds_free >= 0),
    night_doctor BOOLEAN DEFAULT true,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_facilities_capabilities ON facilities USING gin(capabilities);

CREATE TABLE IF NOT EXISTS staff (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE,
    facility_id UUID REFERENCES facilities(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('doctor', 'nurse', 'counter', 'medicine', 'equipment', 'stretcher', 'supervisor', 'operator')),
    team TEXT CHECK (team IN ('counter', 'medicine', 'equipment', 'stretcher') OR team IS NULL),
    pin_hash TEXT NOT NULL DEFAULT '1234',
    is_on_shift BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now())
);
CREATE INDEX IF NOT EXISTS idx_staff_facility_role ON staff(facility_id, role);

CREATE TABLE IF NOT EXISTS playbooks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    version INT DEFAULT 1
);

CREATE TABLE IF NOT EXISTS playbook_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    playbook_id UUID REFERENCES playbooks(id) ON DELETE CASCADE,
    team TEXT NOT NULL CHECK (team IN ('counter', 'medicine', 'equipment', 'stretcher')),
    title TEXT NOT NULL,
    detail TEXT,
    position INT NOT NULL CHECK (position BETWEEN 1 AND 4),
    sla_seconds INT NOT NULL,
    backup_staff UUID REFERENCES staff(id) ON DELETE SET NULL,
    CONSTRAINT uq_playbook_task_pos UNIQUE (playbook_id, position)
);

CREATE TABLE IF NOT EXISTS alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    temp_id TEXT UNIQUE NOT NULL,
    access_token UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    facility_id UUID REFERENCES facilities(id) ON DELETE RESTRICT,
    patient_name TEXT,
    patient_age INT,
    patient_sex TEXT,
    patient_phone TEXT,
    flags JSONB NOT NULL DEFAULT '{}'::jsonb,
    capability_req TEXT[] NOT NULL DEFAULT '{}',
    playbook_key TEXT,
    eta_minutes INT,
    state TEXT NOT NULL DEFAULT 'SENT' CHECK (state IN ('DRAFT', 'SENT', 'ACKNOWLEDGED', 'CLAIMING', 'ALL_CLAIMED', 'ARRIVED', 'CLOSED', 'CANCELLED', 'EXPIRED')),
    created_at TIMESTAMPTZ DEFAULT timezone('utc', now()),
    acknowledged_at TIMESTAMPTZ,
    all_claimed_at TIMESTAMPTZ,
    arrived_at TIMESTAMPTZ,
    closed_at TIMESTAMPTZ,
    cancel_reason TEXT,
    created_by_operator BOOLEAN DEFAULT false,
    expires_at TIMESTAMPTZ,
    client_request_id TEXT UNIQUE
);
CREATE INDEX IF NOT EXISTS idx_alerts_facility_created ON alerts(facility_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_state ON alerts(state);
CREATE INDEX IF NOT EXISTS idx_alerts_temp_id ON alerts(temp_id);

CREATE TABLE IF NOT EXISTS alert_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    task_id UUID REFERENCES playbook_tasks(id) ON DELETE SET NULL,
    team TEXT NOT NULL CHECK (team IN ('counter', 'medicine', 'equipment', 'stretcher')),
    title TEXT NOT NULL,
    detail TEXT,
    sla_seconds INT NOT NULL,
    deadline_at TIMESTAMPTZ NOT NULL,
    claimed_by UUID REFERENCES staff(id) ON DELETE SET NULL,
    claimed_at TIMESTAMPTZ,
    done_at TIMESTAMPTZ,
    escalated_at TIMESTAMPTZ,
    escalation_n INT DEFAULT 0,
    state TEXT DEFAULT 'OPEN' CHECK (state IN ('OPEN', 'CLAIMED', 'DONE', 'ESCALATED')),
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
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_bed_hold ON bed_holds(facility_id, bed_label) WHERE released_at IS NULL AND expires_at > timezone('utc', now());

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

CREATE TABLE IF NOT EXISTS events (
    id BIGSERIAL PRIMARY KEY,
    alert_id UUID REFERENCES alerts(id) ON DELETE CASCADE,
    actor_id UUID,
    actor_role TEXT,
    action TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    at TIMESTAMPTZ DEFAULT timezone('utc', now())
);

CREATE OR REPLACE FUNCTION prevent_event_log_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Event / Audit log entries are strictly immutable. (GoldenHour Rule #5)';
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_events_immutable ON events;
CREATE TRIGGER trg_events_immutable BEFORE UPDATE OR DELETE ON events FOR EACH ROW EXECUTE FUNCTION prevent_event_log_modification();

CREATE TABLE IF NOT EXISTS cancellations (
    id BIGSERIAL PRIMARY KEY,
    alert_id UUID NOT NULL,
    reason TEXT NOT NULL,
    actor_role TEXT,
    at TIMESTAMPTZ DEFAULT timezone('utc', now())
);

CREATE TABLE IF NOT EXISTS notification_outbox (
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
        INSERT INTO alert_tasks (alert_id, task_id, team, title, detail, sla_seconds, deadline_at, state)
        VALUES (NEW.id, v_rec.id, v_rec.team, v_rec.title, v_rec.detail, v_rec.sla_seconds, NEW.created_at + (v_rec.sla_seconds * INTERVAL '1 second'), 'OPEN');
        v_task_count := v_task_count + 1;
    END LOOP;

    IF v_task_count < 4 THEN
        INSERT INTO alert_tasks (alert_id, team, title, detail, sla_seconds, deadline_at) VALUES
        (NEW.id, 'counter', 'Hold ED bed', 'Reserve intake bed in resus bay', 180, NEW.created_at + INTERVAL '180 seconds'),
        (NEW.id, 'medicine', 'Prepare emergency medicines', 'Draw up urgent medication tray', 120, NEW.created_at + INTERVAL '120 seconds'),
        (NEW.id, 'equipment', 'Prepare critical equipment', 'ECG, Defibrillator, O2 to bay', 120, NEW.created_at + INTERVAL '120 seconds'),
        (NEW.id, 'stretcher', 'Trolley & stretcher to gate', 'Meet vehicle at emergency gate', 90, NEW.created_at + INTERVAL '90 seconds');
    END IF;

    UPDATE facilities SET ed_beds_free = GREATEST(0, ed_beds_free - 1) WHERE id = NEW.facility_id AND ed_beds_free > 0;
    INSERT INTO bed_holds (alert_id, facility_id, bed_label, expires_at) VALUES (NEW.id, NEW.facility_id, 'ED-HOLD', timezone('utc', now()) + INTERVAL '30 minutes');

    INSERT INTO events (alert_id, actor_role, action, payload)
    VALUES (NEW.id, 'patient', 'ALERT_CREATED', jsonb_build_object('temp_id', NEW.temp_id, 'facility_id', NEW.facility_id, 'capability_req', NEW.capability_req, 'eta_minutes', NEW.eta_minutes));

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_alerts_spawn_tasks ON alerts;
CREATE TRIGGER trg_alerts_spawn_tasks AFTER INSERT ON alerts FOR EACH ROW EXECUTE FUNCTION spawn_alert_tasks_trigger();

-- -----------------------------------------------------------------------------
-- 4. ENGINE FUNCTIONS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION next_state(p_alert_id UUID, p_action TEXT)
RETURNS TEXT AS $$
DECLARE
    v_alert alerts%ROWTYPE;
    v_all_tasks_claimed BOOLEAN;
    v_new_state TEXT;
BEGIN
    SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alert % not found', p_alert_id; END IF;
    IF v_alert.state IN ('CANCELLED', 'EXPIRED', 'CLOSED') THEN RETURN v_alert.state; END IF;

    IF p_action = 'ACKNOWLEDGE' THEN
        IF v_alert.state = 'SENT' THEN
            v_new_state := 'ACKNOWLEDGED';
            UPDATE alerts SET state = v_new_state, acknowledged_at = timezone('utc', now()) WHERE id = p_alert_id;
            INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'supervisor', 'ACK', '{}'::jsonb);
        ELSE v_new_state := v_alert.state; END IF;
    ELSIF p_action = 'CHECK_CLAIM_PROGRESS' THEN
        SELECT NOT EXISTS(SELECT 1 FROM alert_tasks WHERE alert_id = p_alert_id AND state = 'OPEN') INTO v_all_tasks_claimed;
        IF v_all_tasks_claimed THEN
            v_new_state := 'ALL_CLAIMED';
            UPDATE alerts SET state = v_new_state, all_claimed_at = timezone('utc', now()) WHERE id = p_alert_id;
            INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'system', 'ALL_CLAIMED', '{}'::jsonb);
        ELSE
            IF v_alert.state = 'ACKNOWLEDGED' THEN v_new_state := 'CLAIMING'; UPDATE alerts SET state = v_new_state WHERE id = p_alert_id;
            ELSE v_new_state := v_alert.state; END IF;
        END IF;
    ELSIF p_action = 'ARRIVED' THEN
        v_new_state := 'ARRIVED';
        UPDATE alerts SET state = v_new_state, arrived_at = timezone('utc', now()) WHERE id = p_alert_id;
        INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'counter', 'ARRIVED', '{}'::jsonb);
    ELSIF p_action = 'CLOSE' THEN
        IF v_alert.state != 'ARRIVED' THEN RAISE EXCEPTION 'Cannot close alert before arrival'; END IF;
        v_new_state := 'CLOSED';
        UPDATE alerts SET state = v_new_state, closed_at = timezone('utc', now()) WHERE id = p_alert_id;
        INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'doctor', 'CLOSED', '{}'::jsonb);
    ELSE
        RAISE EXCEPTION 'Illegal action %', p_action;
    END IF;
    RETURN v_new_state;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION claim_task(p_task_id UUID, p_staff_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_task alert_tasks%ROWTYPE;
    v_staff staff%ROWTYPE;
BEGIN
    SELECT * INTO v_staff FROM staff WHERE id = p_staff_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Staff member not found'); END IF;

    UPDATE alert_tasks
    SET state = 'CLAIMED', claimed_by = v_staff.id, claimed_at = timezone('utc', now()), updated_at = timezone('utc', now())
    WHERE id = p_task_id AND state = 'OPEN'
    RETURNING * INTO v_task;

    IF NOT FOUND THEN
        SELECT * INTO v_task FROM alert_tasks WHERE id = p_task_id;
        RETURN jsonb_build_object('success', false, 'already_claimed', true, 'claimed_by', v_task.claimed_by, 'claimed_at', v_task.claimed_at);
    END IF;

    INSERT INTO events (alert_id, actor_id, actor_role, action, payload)
    VALUES (v_task.alert_id, v_staff.id, v_staff.role, 'CLAIM', jsonb_build_object('task_id', v_task.id, 'team', v_task.team, 'title', v_task.title, 'staff_name', v_staff.full_name));

    PERFORM next_state(v_task.alert_id, 'CHECK_CLAIM_PROGRESS');
    RETURN jsonb_build_object('success', true, 'task', row_to_json(v_task));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION escalate_overdue()
RETURNS TABLE (task_id UUID, alert_id UUID, team TEXT, title TEXT, escalation_n INT) AS $$
BEGIN
    RETURN QUERY
    WITH updated_tasks AS (
        UPDATE alert_tasks
        SET state = 'ESCALATED', escalated_at = timezone('utc', now()), escalation_n = escalation_n + 1, updated_at = timezone('utc', now())
        WHERE deadline_at < timezone('utc', now()) AND state = 'OPEN' AND escalated_at IS NULL
        RETURNING alert_tasks.id, alert_tasks.alert_id, alert_tasks.team, alert_tasks.title, alert_tasks.escalation_n
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

CREATE OR REPLACE FUNCTION cancel_alert(p_alert_id UUID, p_reason TEXT DEFAULT 'changed_hospital')
RETURNS JSONB AS $$
DECLARE
    v_alert alerts%ROWTYPE;
BEGIN
    SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Alert not found'); END IF;
    IF v_alert.state IN ('ARRIVED', 'CLOSED') THEN RETURN jsonb_build_object('success', false, 'error', 'Cannot cancel after arrival'); END IF;

    UPDATE alerts SET state = 'CANCELLED', cancel_reason = p_reason WHERE id = p_alert_id;
    UPDATE alert_tasks SET state = 'DONE', done_at = timezone('utc', now()) WHERE alert_id = p_alert_id AND state IN ('OPEN', 'ESCALATED');
    UPDATE bed_holds SET released_at = timezone('utc', now()) WHERE alert_id = p_alert_id AND released_at IS NULL;
    UPDATE facilities SET ed_beds_free = ed_beds_free + 1 WHERE id = v_alert.facility_id;

    INSERT INTO cancellations (alert_id, reason, actor_role) VALUES (p_alert_id, p_reason, 'patient');
    INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'patient', 'CANCEL', jsonb_build_object('reason', p_reason));

    RETURN jsonb_build_object('success', true, 'state', 'CANCELLED');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
        WHERE state IN ('SENT', 'ACKNOWLEDGED', 'CLAIMING', 'ALL_CLAIMED') AND expires_at IS NOT NULL AND expires_at < timezone('utc', now())
        RETURNING id, facility_id
    )
    SELECT COUNT(*) INTO v_expired_alerts_count FROM exp_alerts;

    WITH expired_holds AS (
        UPDATE bed_holds SET released_at = timezone('utc', now())
        WHERE released_at IS NULL AND expires_at < timezone('utc', now())
        RETURNING facility_id
    )
    UPDATE facilities f SET ed_beds_free = ed_beds_free + 1 FROM expired_holds eh WHERE f.id = eh.facility_id;
    GET DIAGNOSTICS v_released_holds_count = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'tick_at', timezone('utc', now()), 'tasks_escalated', v_escalated_count, 'alerts_expired', v_expired_alerts_count, 'holds_released', v_released_holds_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 5. VIEWS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW nurse_safe_view AS
SELECT 
    r.alert_id,
    a.temp_id,
    bh.bed_label,
    t.title AS current_task,
    t.state AS task_state,
    GREATEST(0, EXTRACT(EPOCH FROM (t.deadline_at - timezone('utc', now())))::INT / 60) AS minutes_remaining,
    r.safe_summary->'medicines' AS medicines,
    r.safe_summary->'allergies' AS allergies,
    r.safe_summary->'watch_for' AS watch_for
FROM records r
JOIN alerts a ON r.alert_id = a.id
LEFT JOIN bed_holds bh ON bh.alert_id = a.id AND bh.released_at IS NULL
LEFT JOIN alert_tasks t ON t.alert_id = a.id AND t.team = 'medicine';

CREATE OR REPLACE VIEW ops_metrics_view AS
SELECT 
    f.id AS facility_id,
    f.name AS facility_name,
    COUNT(a.id) AS total_alerts_today,
    COUNT(CASE WHEN a.state IN ('ALL_CLAIMED', 'ARRIVED', 'CLOSED') THEN 1 END) AS successful_alerts,
    COUNT(CASE WHEN a.state = 'CANCELLED' THEN 1 END) AS cancelled_alerts,
    ROUND(COUNT(CASE WHEN a.state = 'CANCELLED' THEN 1 END)::NUMERIC / GREATEST(1, COUNT(a.id)) * 100, 1) AS cancellation_rate_pct,
    COUNT(CASE WHEN at.escalated_at IS NOT NULL THEN 1 END) AS total_escalated_tasks,
    COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (at.claimed_at - a.created_at))), 45)::INT AS median_seconds_to_claim
FROM facilities f
LEFT JOIN alerts a ON a.facility_id = f.id AND a.created_at >= timezone('utc', now() - INTERVAL '24 hours')
LEFT JOIN alert_tasks at ON at.alert_id = a.id
GROUP BY f.id, f.name;

CREATE OR REPLACE VIEW cancelled_alerts_view AS
SELECT 
    c.id AS cancellation_id,
    c.alert_id,
    a.temp_id,
    a.facility_id,
    f.name AS facility_name,
    c.reason,
    c.actor_role,
    c.at AS cancelled_at,
    bh.bed_label,
    EXTRACT(EPOCH FROM (c.at - a.created_at))::INT AS hold_duration_seconds
FROM cancellations c
JOIN alerts a ON c.alert_id = a.id
JOIN facilities f ON a.facility_id = f.id
LEFT JOIN bed_holds bh ON bh.alert_id = a.id;

-- -----------------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY (RLS)
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

CREATE POLICY "Public can view active facilities" ON facilities FOR SELECT USING (is_active = true);
CREATE POLICY "Allow staff PIN and profile lookup" ON staff FOR SELECT USING (is_on_shift = true);
CREATE POLICY "Anyone can read playbooks" ON playbooks FOR SELECT USING (true);
CREATE POLICY "Anyone can read playbook tasks" ON playbook_tasks FOR SELECT USING (true);
CREATE POLICY "Public can create alert" ON alerts FOR INSERT WITH CHECK (true);
CREATE POLICY "Patient can view own alert" ON alerts FOR SELECT USING (true);
CREATE POLICY "Patient can cancel own alert" ON alerts FOR UPDATE USING (true);
CREATE POLICY "Staff can view tasks for their facility" ON alert_tasks FOR SELECT USING (true);
CREATE POLICY "Staff can claim tasks for their facility" ON alert_tasks FOR UPDATE USING (true);
CREATE POLICY "Counter and supervisor can view bed holds" ON bed_holds FOR ALL USING (true);
CREATE POLICY "Doctor can view and write records" ON records FOR ALL USING (true);
CREATE POLICY "Allow event inserts" ON events FOR INSERT WITH CHECK (true);
CREATE POLICY "Staff can view events" ON events FOR SELECT USING (true);
CREATE POLICY "Allow cancellation inserts" ON cancellations FOR INSERT WITH CHECK (true);
CREATE POLICY "Staff can view cancellations" ON cancellations FOR SELECT USING (true);
CREATE POLICY "Allow outbox inserts and updates" ON notification_outbox FOR ALL USING (true);

-- -----------------------------------------------------------------------------
-- 7. ENABLE REALTIME PUBLICATION
-- -----------------------------------------------------------------------------
ALTER PUBLICATION supabase_realtime ADD TABLE alerts;
ALTER PUBLICATION supabase_realtime ADD TABLE alert_tasks;
ALTER PUBLICATION supabase_realtime ADD TABLE bed_holds;
ALTER PUBLICATION supabase_realtime ADD TABLE notification_outbox;

-- -----------------------------------------------------------------------------
-- 8. SEED DATA (3 Facilities, 8 Staff, 3 Playbooks)
-- -----------------------------------------------------------------------------
INSERT INTO facilities (id, name, area, phone, distance_min, capabilities, ed_beds_total, ed_beds_free, night_doctor, is_active) VALUES
('11111111-1111-1111-1111-111111111111', 'Sunrise Hospital, Cuttack', 'Mangalabag, Cuttack', '+91-671-2414080', 8, ARRAY['ecg','defib','oxygen','ct','usg','blood','ot','icu','ventilator','cardiac_team','thrombolysis','cath_lab'], 15, 6, true, true),
('22222222-2222-2222-2222-222222222222', 'Capital Hospital, Bhubaneswar', 'Unit 6, Bhubaneswar', '+91-674-2391983', 14, ARRAY['ecg','oxygen','ct','usg','blood','ot','icu','ventilator'], 20, 4, true, true),
('33333333-3333-3333-3333-333333333333', 'Kalinga Care Clinic', 'Buxi Bazaar, Cuttack', '+91-671-2300112', 4, ARRAY['ecg','oxygen'], 4, 1, false, true)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, capabilities = EXCLUDED.capabilities;

INSERT INTO staff (id, facility_id, full_name, role, team, pin_hash, is_on_shift) VALUES
('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Dr. Pragyan Mohanty', 'supervisor', NULL, '1234', true),
('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Dr. Alok Nayak', 'doctor', NULL, '1234', true),
('a0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Nurse Sneha Rout', 'nurse', NULL, '1234', true),
('a0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Priyanka Behera', 'counter', 'counter', '1234', true),
('a0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Pharm. Manoj Jena', 'medicine', 'medicine', '1234', true),
('a0000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'Pharm. Sunita Das', 'medicine', 'medicine', '1234', true),
('a0000000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'Tech. Bikas Patra', 'equipment', 'equipment', '1234', true),
('a0000000-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'Ranjan Sahoo', 'stretcher', 'stretcher', '1234', true)
ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name, role = EXCLUDED.role;

INSERT INTO playbooks (id, key, name, version) VALUES
('b0000000-0000-0000-0000-000000000001', 'cardiac', 'Cardiac Emergency Playbook', 1),
('b0000000-0000-0000-0000-000000000002', 'stroke', 'Acute Stroke Playbook', 1),
('b0000000-0000-0000-0000-000000000003', 'trauma', 'Major Trauma Playbook', 1)
ON CONFLICT (key) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO playbook_tasks (playbook_id, team, title, detail, position, sla_seconds) VALUES
('b0000000-0000-0000-0000-000000000001', 'counter', 'Hold ED bed', 'Reserve intake bed in cardiac bay and alert duty doctor', 1, 180),
('b0000000-0000-0000-0000-000000000001', 'medicine', 'Prepare aspirin + GTN tray', 'Draw up urgent medication tray and oxygen mask', 2, 120),
('b0000000-0000-0000-0000-000000000001', 'equipment', 'ECG machine + defibrillator to bay', 'Position ECG lead set and calibrate defib in bay 2', 3, 120),
('b0000000-0000-0000-0000-000000000001', 'stretcher', 'Trolley to gate & wheelchair ready', 'Meet ambulance at casualty entrance with oxygen cylinder', 4, 90),

('b0000000-0000-0000-0000-000000000002', 'counter', 'Hold ED bed · alert doctor', 'Check CT availability and notify on-call neurologist', 1, 180),
('b0000000-0000-0000-0000-000000000002', 'medicine', 'Prepare IV line · BP tray', 'Prepare thrombolytic candidate kit and glucometer', 2, 120),
('b0000000-0000-0000-0000-000000000002', 'equipment', 'CT slot flagged · oxygen', 'Clear path directly to CT scanner suite', 3, 120),
('b0000000-0000-0000-0000-000000000002', 'stretcher', 'Trolley to gate', 'Transfer patient from vehicle directly to CT trolley', 4, 90),

('b0000000-0000-0000-0000-000000000003', 'counter', 'Hold bed · alert surgeon', 'Notify emergency surgeon and alert blood bank', 1, 180),
('b0000000-0000-0000-0000-000000000003', 'medicine', 'Prepare trauma tray · IV fluids', 'Warm normal saline, pressure infusers, hemostatic dressings', 2, 120),
('b0000000-0000-0000-0000-000000000003', 'equipment', 'Oxygen + suction + dressing trolley', 'Check wall suction pressure and portable emergency unit', 3, 120),
('b0000000-0000-0000-0000-000000000003', 'stretcher', 'Trolley + spine board to gate', 'Have cervical collar and spine board ready at entrance', 4, 90)
ON CONFLICT (playbook_id, position) DO UPDATE SET title = EXCLUDED.title, sla_seconds = EXCLUDED.sla_seconds;

-- -----------------------------------------------------------------------------
-- 9. DEMO ACTIVE ALERT (GH-4F7K, 8 min out)
-- -----------------------------------------------------------------------------
INSERT INTO alerts (id, temp_id, access_token, facility_id, patient_name, patient_age, patient_sex, flags, capability_req, playbook_key, eta_minutes, state, created_at)
VALUES (
    'c0000000-0000-0000-0000-000000000001',
    'GH-4F7K',
    'f0000000-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    'Priya Mohapatra', 62, 'F',
    '{"chest_pain": true, "sweating": true, "breathless": true}'::jsonb,
    ARRAY['ecg', 'defib', 'cardiac_team', 'oxygen'],
    'cardiac', 8, 'SENT', timezone('utc', now() - INTERVAL '30 seconds')
)
ON CONFLICT (id) DO NOTHING;
