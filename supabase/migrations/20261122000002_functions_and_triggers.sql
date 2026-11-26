-- =============================================================================
-- Migration 002: Functions, Stored Procedures, and Triggers for GoldenHour
-- Implements Atomic Claiming, Dynamic Server Escalation, Resource Management,
-- and Append-Only Audit Integrity.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. IMMUTABLE AUDIT LOG TRIGGER
-- Enforces PRD Requirement: "Nothing is edited, only added. Append-only audit trail."
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION prevent_audit_log_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Audit log entries are immutable and cannot be updated or deleted. (GoldenHour Rule #5)';
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_log_immutable ON audit_logs;
CREATE TRIGGER trg_audit_log_immutable
BEFORE UPDATE OR DELETE ON audit_logs
FOR EACH ROW
EXECUTE FUNCTION prevent_audit_log_modification();

-- -----------------------------------------------------------------------------
-- 2. 6-CHARACTER ALERT CODE GENERATOR
-- Generates human-friendly 6-character uppercase codes (e.g., A3F2C1)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_unique_alert_code()
RETURNS VARCHAR(6) AS $$
DECLARE
    v_chars CONSTANT TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- Excludes confusing 0, 1, I, O
    v_code VARCHAR(6) := '';
    v_exists BOOLEAN := true;
    v_i INTEGER;
BEGIN
    WHILE v_exists LOOP
        v_code := '';
        FOR v_i IN 1..6 LOOP
            v_code := v_code || substr(v_chars, floor(random() * length(v_chars) + 1)::integer, 1);
        END LOOP;
        SELECT EXISTS(SELECT 1 FROM alerts WHERE alert_code = v_code) INTO v_exists;
    END LOOP;
    RETURN v_code;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 3. AUTO-GENERATE 4 PREPARATION TASKS UPON ALERT CREATION
-- Pulls the 4 defined tasks from task_templates (or standard defaults)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION handle_new_alert_created()
RETURNS TRIGGER AS $$
DECLARE
    v_rec RECORD;
    v_task_count INTEGER := 0;
BEGIN
    -- 1. Ensure alert code is populated
    IF NEW.alert_code IS NULL OR NEW.alert_code = '' THEN
        NEW.alert_code := generate_unique_alert_code();
    END IF;

    -- 2. Ephemeral Bed Hold (Timer: 30 minutes)
    -- Reserve bed if available
    UPDATE hospital_resources
    SET available_emergency_beds = GREATEST(0, available_emergency_beds - 1),
        held_beds = held_beds + 1,
        last_updated_at = timezone('utc', now()),
        updated_by = 'Alert ' || NEW.alert_code
    WHERE hospital_id = NEW.hospital_id AND available_emergency_beds > 0;

    IF FOUND THEN
        NEW.bed_held := true;
        NEW.bed_held_expires_at := timezone('utc', now()) + INTERVAL '30 minutes';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_alert_before_insert ON alerts;
CREATE TRIGGER trg_alert_before_insert
BEFORE INSERT ON alerts
FOR EACH ROW
EXECUTE FUNCTION handle_new_alert_created();

-- Trigger AFTER insert to spawn exactly 4 tasks and log audit
CREATE OR REPLACE FUNCTION handle_new_alert_tasks_spawn()
RETURNS TRIGGER AS $$
DECLARE
    v_rec RECORD;
    v_task_count INTEGER := 0;
BEGIN
    -- Populate 4 tasks from hospital-specific template or default template
    FOR v_rec IN 
        SELECT task_sequence, role_required, title_en, title_or 
        FROM task_templates 
        WHERE (hospital_id = NEW.hospital_id OR hospital_id IS NULL)
          AND category = NEW.category
        ORDER BY hospital_id NULLS LAST, task_sequence ASC
        LIMIT 4
    LOOP
        INSERT INTO alert_tasks (
            alert_id,
            task_sequence,
            role_required,
            title_en,
            title_or,
            status,
            escalation_level
        ) VALUES (
            NEW.id,
            v_rec.task_sequence,
            v_rec.role_required,
            v_rec.title_en,
            v_rec.title_or,
            'unclaimed',
            'normal'
        );
        v_task_count := v_task_count + 1;
    END LOOP;

    -- Fallback safety: If no templates configured, insert standard 4 roles
    IF v_task_count < 4 THEN
        IF NOT EXISTS (SELECT 1 FROM alert_tasks WHERE alert_id = NEW.id AND task_sequence = 1) THEN
            INSERT INTO alert_tasks (alert_id, task_sequence, role_required, title_en, title_or)
            VALUES (NEW.id, 1, 'doctor', 'Emergency Doctor Ready', 'ଡାକ୍ତର ପ୍ରସ୍ତୁତ ରୁହନ୍ତୁ');
        END IF;
        IF NOT EXISTS (SELECT 1 FROM alert_tasks WHERE alert_id = NEW.id AND task_sequence = 2) THEN
            INSERT INTO alert_tasks (alert_id, task_sequence, role_required, title_en, title_or)
            VALUES (NEW.id, 2, 'nurse', 'Emergency Bed Prepared', 'ଜରୁରୀକାଳୀନ ଶଯ୍ୟା ପ୍ରସ୍ତୁତ କରନ୍ତୁ');
        END IF;
        IF NOT EXISTS (SELECT 1 FROM alert_tasks WHERE alert_id = NEW.id AND task_sequence = 3) THEN
            INSERT INTO alert_tasks (alert_id, task_sequence, role_required, title_en, title_or)
            VALUES (NEW.id, 3, 'pharmacy', 'Emergency Medication Kit Prepared', 'ଔଷଧ କିଟ୍ ପ୍ରସ୍ତୁତ ରଖନ୍ତୁ');
        END IF;
        IF NOT EXISTS (SELECT 1 FROM alert_tasks WHERE alert_id = NEW.id AND task_sequence = 4) THEN
            INSERT INTO alert_tasks (alert_id, task_sequence, role_required, title_en, title_or)
            VALUES (NEW.id, 4, 'transport', 'Stretcher and Oxygen at Gate', 'ଗେଟ୍ ନିକଟରେ ଷ୍ଟ୍ରେଚର୍ ଏବଂ ଅମ୍ଳଜାନ');
        END IF;
    END IF;

    -- Write initial creation to audit log
    INSERT INTO audit_logs (
        alert_id,
        action,
        actor_type,
        actor_id,
        actor_role,
        details
    ) VALUES (
        NEW.id,
        'ALERT_CREATED',
        'family',
        NEW.access_token::text,
        'family',
        jsonb_build_object(
            'alert_code', NEW.alert_code,
            'category', NEW.category,
            'hospital_id', NEW.hospital_id,
            'bed_held', NEW.bed_held,
            'estimated_minutes', NEW.estimated_drive_minutes
        )
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_alert_after_insert ON alerts;
CREATE TRIGGER trg_alert_after_insert
AFTER INSERT ON alerts
FOR EACH ROW
EXECUTE FUNCTION handle_new_alert_tasks_spawn();

-- -----------------------------------------------------------------------------
-- 4. ATOMIC TASK CLAIMING FUNCTION (SOLVES CONCURRENCY RACE CONDITION)
-- PRD Rule #9: "If two nurses tap 'claim' at the same moment, one wins and
-- the other is told who won. Nobody is sent twice."
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_task(
    p_task_id UUID,
    p_staff_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_task alert_tasks%ROWTYPE;
    v_staff staff_members%ROWTYPE;
    v_alert alerts%ROWTYPE;
    v_unclaimed_remaining INTEGER;
BEGIN
    -- 1. Fetch claiming staff details
    SELECT * INTO v_staff FROM staff_members WHERE id = p_staff_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Staff member not found or invalid PIN'
        );
    END IF;

    -- 2. Atomic Update: only updates if task is strictly 'unclaimed'
    UPDATE alert_tasks
    SET status = 'claimed',
        claimed_by = v_staff.id,
        claimed_by_name = v_staff.name,
        claimed_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    WHERE id = p_task_id
      AND status = 'unclaimed'
    RETURNING * INTO v_task;

    -- 3. Check if someone else beat them to it
    IF NOT FOUND THEN
        SELECT * INTO v_task FROM alert_tasks WHERE id = p_task_id;
        RETURN jsonb_build_object(
            'success', false,
            'already_claimed', true,
            'message', 'Task already claimed',
            'claimed_by_name', v_task.claimed_by_name,
            'claimed_at', v_task.claimed_at
        );
    END IF;

    -- 4. Log successful claim to audit trail
    INSERT INTO audit_logs (
        alert_id,
        action,
        actor_type,
        actor_id,
        actor_role,
        details
    ) VALUES (
        v_task.alert_id,
        'TASK_CLAIMED',
        'staff',
        v_staff.id::text,
        v_staff.role::text,
        jsonb_build_object(
            'task_id', v_task.id,
            'task_sequence', v_task.task_sequence,
            'task_title', v_task.title_en,
            'staff_name', v_staff.name,
            'escalation_level', v_task.escalation_level
        )
    );

    -- 5. Check if all 4 tasks for this alert are claimed -> Alert turns 'ready'
    SELECT COUNT(*) INTO v_unclaimed_remaining
    FROM alert_tasks
    WHERE alert_id = v_task.alert_id AND status = 'unclaimed';

    IF v_unclaimed_remaining = 0 THEN
        UPDATE alerts
        SET status = 'ready',
            all_tasks_claimed_at = timezone('utc', now())
        WHERE id = v_task.alert_id
          AND status IN ('created', 'acknowledged');

        INSERT INTO audit_logs (
            alert_id,
            action,
            actor_type,
            actor_id,
            actor_role,
            details
        ) VALUES (
            v_task.alert_id,
            'ALL_TASKS_CLAIMED',
            'system',
            'system',
            'ops_wall',
            jsonb_build_object('message', 'All 4 tasks claimed. Hospital is READY.')
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'task', row_to_json(v_task),
        'all_claimed', (v_unclaimed_remaining = 0)
    );
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 5. ESCALATION EVALUATION FUNCTION (90s Amber, 180s Red)
-- Runs on server clock; flags amber at 90s, red at 180s.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evaluate_alert_escalations(p_alert_id UUID DEFAULT NULL)
RETURNS TABLE (
    alert_id UUID,
    alert_code VARCHAR(6),
    elapsed_seconds INTEGER,
    unclaimed_tasks INTEGER,
    new_escalation VARCHAR(20)
) AS $$
BEGIN
    RETURN QUERY
    WITH alert_elapsed AS (
        SELECT 
            a.id,
            a.alert_code,
            EXTRACT(EPOCH FROM (timezone('utc', now()) - a.created_at))::INTEGER AS elapsed_sec,
            a.status
        FROM alerts a
        WHERE a.status IN ('created', 'acknowledged', 'ready')
          AND (p_alert_id IS NULL OR a.id = p_alert_id)
    ),
    amber_updates AS (
        -- Escalate unclaimed tasks to Amber at 90 seconds
        UPDATE alert_tasks t
        SET escalation_level = 'amber',
            amber_escalated_at = timezone('utc', now()),
            updated_at = timezone('utc', now())
        FROM alert_elapsed ae
        WHERE t.alert_id = ae.id
          AND t.status = 'unclaimed'
          AND t.escalation_level = 'normal'
          AND ae.elapsed_sec >= 90
        RETURNING t.alert_id
    ),
    red_updates AS (
        -- Escalate unclaimed tasks to Red at 180 seconds (3 minutes)
        UPDATE alert_tasks t
        SET escalation_level = 'red',
            red_escalated_at = timezone('utc', now()),
            updated_at = timezone('utc', now())
        FROM alert_elapsed ae
        WHERE t.alert_id = ae.id
          AND t.status = 'unclaimed'
          AND t.escalation_level = 'amber'
          AND ae.elapsed_sec >= 180
        RETURNING t.alert_id
    )
    SELECT 
        ae.id,
        ae.alert_code,
        ae.elapsed_sec,
        (SELECT COUNT(*)::INTEGER FROM alert_tasks at WHERE at.alert_id = ae.id AND at.status = 'unclaimed'),
        CASE 
            WHEN ae.elapsed_sec >= 180 THEN 'red'::VARCHAR(20)
            WHEN ae.elapsed_sec >= 90 THEN 'amber'::VARCHAR(20)
            ELSE 'normal'::VARCHAR(20)
        END
    FROM alert_elapsed ae;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 6. RESOURCE RELEASE TRIGGER ON ARRIVAL / CLOSURE / CANCEL / DIVERT
-- Releases or transitions bed holds cleanly
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION handle_alert_status_transition()
RETURNS TRIGGER AS $$
BEGIN
    -- 1. "Arriving always wins": Arrival stops escalation clock
    IF NEW.status = 'arrived' AND OLD.status != 'arrived' THEN
        NEW.arrived_at := timezone('utc', now());
        
        -- Transition held bed to occupied bed in department
        IF OLD.bed_held THEN
            UPDATE hospital_resources
            SET held_beds = GREATEST(0, held_beds - 1),
                last_updated_at = timezone('utc', now()),
                updated_by = 'Arrival ' || NEW.alert_code
            WHERE hospital_id = NEW.hospital_id;
            NEW.bed_held := false;
        END IF;

        INSERT INTO audit_logs (
            alert_id, action, actor_type, actor_id, actor_role, details
        ) VALUES (
            NEW.id, 'PATIENT_ARRIVED', 'staff', 'front_desk', 'counter',
            jsonb_build_object('arrived_at', NEW.arrived_at)
        );
    END IF;

    -- 2. Case Closed: Complete closure record
    IF NEW.status = 'closed' AND OLD.status != 'closed' THEN
        NEW.closed_at := timezone('utc', now());

        -- Free bed if it was still held
        IF OLD.bed_held THEN
            UPDATE hospital_resources
            SET held_beds = GREATEST(0, held_beds - 1),
                available_emergency_beds = available_emergency_beds + 1,
                last_updated_at = timezone('utc', now()),
                updated_by = 'Closed ' || NEW.alert_code
            WHERE hospital_id = NEW.hospital_id;
            NEW.bed_held := false;
        END IF;

        INSERT INTO audit_logs (
            alert_id, action, actor_type, actor_id, actor_role, details
        ) VALUES (
            NEW.id, 'ALERT_CLOSED', 'staff', COALESCE(NEW.closed_by::text, 'duty_doctor'), 'doctor',
            jsonb_build_object('closed_at', NEW.closed_at, 'summary', NEW.closure_summary)
        );
    END IF;

    -- 3. Case Cancelled by Family: Immediately release held bed
    IF NEW.status = 'cancelled' AND OLD.status != 'cancelled' THEN
        IF OLD.bed_held THEN
            UPDATE hospital_resources
            SET held_beds = GREATEST(0, held_beds - 1),
                available_emergency_beds = available_emergency_beds + 1,
                last_updated_at = timezone('utc', now()),
                updated_by = 'Cancelled ' || NEW.alert_code
            WHERE hospital_id = NEW.hospital_id;
            NEW.bed_held := false;
        END IF;

        INSERT INTO audit_logs (
            alert_id, action, actor_type, actor_id, actor_role, details
        ) VALUES (
            NEW.id, 'ALERT_CANCELLED', 'family', NEW.access_token::text, 'family',
            jsonb_build_object('reason', NEW.cancellation_reason)
        );
    END IF;

    -- 4. Case Diverted / Refused: Release held bed immediately
    IF NEW.status = 'diverted' AND OLD.status != 'diverted' THEN
        IF OLD.bed_held THEN
            UPDATE hospital_resources
            SET held_beds = GREATEST(0, held_beds - 1),
                available_emergency_beds = available_emergency_beds + 1,
                last_updated_at = timezone('utc', now()),
                updated_by = 'Diverted ' || NEW.alert_code
            WHERE hospital_id = NEW.hospital_id;
            NEW.bed_held := false;
        END IF;

        INSERT INTO audit_logs (
            alert_id, action, actor_type, actor_id, actor_role, details
        ) VALUES (
            NEW.id, 'ALERT_DIVERTED', 'staff', 'in_charge', 'in_charge',
            jsonb_build_object(
                'reason', NEW.diversion_reason,
                'notes', NEW.diversion_notes,
                'diverted_to', NEW.diverted_to_hospital_id
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_alert_status_transition ON alerts;
CREATE TRIGGER trg_alert_status_transition
BEFORE UPDATE ON alerts
FOR EACH ROW
EXECUTE FUNCTION handle_alert_status_transition();

-- -----------------------------------------------------------------------------
-- 7. DYNAMIC SERVER-CLOCK ESCALATION VIEW
-- PRD Rule #2: "The deadline is computed from a stored timestamp whenever
-- a screen asks. A refresh or a closed tab cannot pause an escalation."
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_active_alerts_escalation AS
SELECT 
    a.id AS alert_id,
    a.alert_code,
    a.hospital_id,
    h.name AS hospital_name,
    a.category,
    a.status AS alert_status,
    a.estimated_distance_km,
    a.estimated_drive_minutes,
    a.created_at,
    a.arrived_at,
    -- Exact server-computed elapsed seconds
    EXTRACT(EPOCH FROM (timezone('utc', now()) - a.created_at))::INTEGER AS elapsed_seconds,
    -- Task claim stats
    COUNT(t.id) AS total_tasks,
    COUNT(CASE WHEN t.status = 'claimed' THEN 1 END) AS claimed_tasks_count,
    COUNT(CASE WHEN t.status = 'unclaimed' THEN 1 END) AS unclaimed_tasks_count,
    -- Overall visual status indicator for Ops Wall
    CASE 
        WHEN a.status = 'arrived' THEN 'ARRIVED'
        WHEN a.status = 'closed' THEN 'CLOSED'
        WHEN COUNT(CASE WHEN t.status = 'claimed' THEN 1 END) = 4 THEN 'ALL_TAKEN'
        WHEN EXTRACT(EPOCH FROM (timezone('utc', now()) - a.created_at)) >= 180 AND COUNT(CASE WHEN t.status = 'unclaimed' THEN 1 END) > 0 THEN 'RED'
        WHEN EXTRACT(EPOCH FROM (timezone('utc', now()) - a.created_at)) >= 90 AND COUNT(CASE WHEN t.status = 'unclaimed' THEN 1 END) > 0 THEN 'AMBER'
        ELSE 'NORMAL'
    END AS visual_status,
    -- Plain text representation for 3-meter wall readability
    CASE 
        WHEN COUNT(CASE WHEN t.status = 'claimed' THEN 1 END) = 4 THEN 'ALL TAKEN'
        WHEN EXTRACT(EPOCH FROM (timezone('utc', now()) - a.created_at)) >= 180 THEN 'RED: CRITICAL'
        WHEN EXTRACT(EPOCH FROM (timezone('utc', now()) - a.created_at)) >= 90 THEN 'AMBER: UNCLAIMED'
        ELSE (COUNT(CASE WHEN t.status = 'claimed' THEN 1 END) || ' of 4 TAKEN')
    END AS display_badge
FROM alerts a
JOIN hospitals h ON a.hospital_id = h.id
LEFT JOIN alert_tasks t ON a.id = t.alert_id
WHERE a.status IN ('created', 'acknowledged', 'ready', 'arrived')
GROUP BY a.id, a.alert_code, a.hospital_id, h.name, a.category, a.status, a.estimated_distance_km, a.estimated_drive_minutes, a.created_at, a.arrived_at;
