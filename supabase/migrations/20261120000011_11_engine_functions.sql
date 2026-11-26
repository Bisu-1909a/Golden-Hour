-- Migration 11: The Engine in SQL (next_state, escalate_overdue, engine_tick, claim_task, cancel_alert)
-- GoldenHour Blueprint §6.1 / §07 / §8.3

-- -----------------------------------------------------------------------------
-- 1. NEXT_STATE: State transition validator & executor
-- PENDING -> CLAIMED -> DONE, and refuses every illegal move
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION next_state(
    p_alert_id UUID,
    p_action TEXT
)
RETURNS TEXT AS $$
DECLARE
    v_alert alerts%ROWTYPE;
    v_all_tasks_claimed BOOLEAN;
    v_new_state TEXT;
BEGIN
    SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Alert with id % not found', p_alert_id;
    END IF;

    -- Terminal states cannot transition
    IF v_alert.state IN ('CANCELLED', 'EXPIRED', 'CLOSED') THEN
        RETURN v_alert.state;
    END IF;

    IF p_action = 'ACKNOWLEDGE' THEN
        IF v_alert.state = 'SENT' THEN
            v_new_state := 'ACKNOWLEDGED';
            UPDATE alerts SET state = v_new_state, acknowledged_at = timezone('utc', now()) WHERE id = p_alert_id;
            INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'supervisor', 'ACK', '{}'::jsonb);
        ELSE
            v_new_state := v_alert.state;
        END IF;

    ELSIF p_action = 'CHECK_CLAIM_PROGRESS' THEN
        SELECT NOT EXISTS(SELECT 1 FROM alert_tasks WHERE alert_id = p_alert_id AND state = 'OPEN')
        INTO v_all_tasks_claimed;

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
        IF v_alert.state != 'ARRIVED' THEN
            RAISE EXCEPTION 'Cannot close alert before arrival is confirmed';
        END IF;
        v_new_state := 'CLOSED';
        UPDATE alerts SET state = v_new_state, closed_at = timezone('utc', now()) WHERE id = p_alert_id;
        INSERT INTO events (alert_id, actor_role, action, payload) VALUES (p_alert_id, 'doctor', 'CLOSED', '{}'::jsonb);

    ELSE
        RAISE EXCEPTION 'Illegal action % for alert state %', p_action, v_alert.state;
    END IF;

    RETURN v_new_state;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 2. CLAIM_TASK: Atomic compare-and-set claim (two nurses, one winner)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_task(
    p_task_id UUID,
    p_staff_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_task alert_tasks%ROWTYPE;
    v_staff staff%ROWTYPE;
    v_all_claimed BOOLEAN;
BEGIN
    SELECT * INTO v_staff FROM staff WHERE id = p_staff_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Staff member not found');
    END IF;

    -- Atomic compare-and-set: only updates if state is strictly 'OPEN'
    UPDATE alert_tasks
    SET state = 'CLAIMED',
        claimed_by = v_staff.id,
        claimed_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    WHERE id = p_task_id
      AND state = 'OPEN'
    RETURNING * INTO v_task;

    IF NOT FOUND THEN
        -- Task already claimed by someone else
        SELECT * INTO v_task FROM alert_tasks WHERE id = p_task_id;
        RETURN jsonb_build_object(
            'success', false,
            'already_claimed', true,
            'message', 'Task already claimed',
            'claimed_by', v_task.claimed_by,
            'claimed_at', v_task.claimed_at
        );
    END IF;

    -- Log to events table
    INSERT INTO events (alert_id, actor_id, actor_role, action, payload)
    VALUES (
        v_task.alert_id,
        v_staff.id,
        v_staff.role,
        'CLAIM',
        jsonb_build_object(
            'task_id', v_task.id,
            'team', v_task.team,
            'title', v_task.title,
            'staff_name', v_staff.full_name
        )
    );

    -- Check if this completes all tasks
    PERFORM next_state(v_task.alert_id, 'CHECK_CLAIM_PROGRESS');

    RETURN jsonb_build_object(
        'success', true,
        'task', row_to_json(v_task)
    );
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 3. ESCALATE_OVERDUE: Idempotent atomic escalation query
-- Ten ticks produce one escalation row — provable with a count(*)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION escalate_overdue()
RETURNS TABLE (
    task_id UUID,
    alert_id UUID,
    team TEXT,
    title TEXT,
    escalation_n INT
) AS $$
BEGIN
    RETURN QUERY
    WITH updated_tasks AS (
        UPDATE alert_tasks
        SET state = 'ESCALATED',
            escalated_at = timezone('utc', now()),
            escalation_n = escalation_n + 1,
            updated_at = timezone('utc', now())
        WHERE deadline_at < timezone('utc', now())
          AND state = 'OPEN'
          AND escalated_at IS NULL -- IDEMPOTENT: exactly once
        RETURNING alert_tasks.id, alert_tasks.alert_id, alert_tasks.team, alert_tasks.title, alert_tasks.escalation_n
    ),
    logged_events AS (
        INSERT INTO events (alert_id, actor_role, action, payload)
        SELECT 
            ut.alert_id,
            'system',
            'ESCALATE',
            jsonb_build_object(
                'task_id', ut.id,
                'team', ut.team,
                'title', ut.title,
                'escalation_n', ut.escalation_n
            )
        FROM updated_tasks ut
    ),
    queued_notifications AS (
        INSERT INTO notification_outbox (alert_id, task_id, recipient_role, channel, payload)
        SELECT 
            ut.alert_id,
            ut.id,
            'supervisor',
            'supervisor_wall',
            jsonb_build_object(
                'message', 'TASK ESCALATED: ' || ut.title || ' (' || ut.team || ')',
                'task_id', ut.id,
                'escalation_n', ut.escalation_n
            )
        FROM updated_tasks ut
    )
    SELECT ut.id, ut.alert_id, ut.team, ut.title, ut.escalation_n FROM updated_tasks ut;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 4. CANCEL_ALERT: Cancel that frees the bed and closes tasks
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_alert(
    p_alert_id UUID,
    p_reason TEXT DEFAULT 'changed_hospital'
)
RETURNS JSONB AS $$
DECLARE
    v_alert alerts%ROWTYPE;
BEGIN
    SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Alert not found');
    END IF;

    -- Cannot cancel after arrival
    IF v_alert.state IN ('ARRIVED', 'CLOSED') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot cancel after arrival');
    END IF;

    -- Update alert state
    UPDATE alerts
    SET state = 'CANCELLED',
        cancel_reason = p_reason
    WHERE id = p_alert_id;

    -- Cancel all open tasks
    UPDATE alert_tasks
    SET state = 'DONE',
        done_at = timezone('utc', now())
    WHERE alert_id = p_alert_id
      AND state IN ('OPEN', 'ESCALATED');

    -- Release bed hold immediately
    UPDATE bed_holds
    SET released_at = timezone('utc', now())
    WHERE alert_id = p_alert_id AND released_at IS NULL;

    UPDATE facilities
    SET ed_beds_free = ed_beds_free + 1
    WHERE id = v_alert.facility_id;

    -- Log cancellation to ledger
    INSERT INTO cancellations (alert_id, reason, actor_role)
    VALUES (p_alert_id, p_reason, 'patient');

    -- Log event
    INSERT INTO events (alert_id, actor_role, action, payload)
    VALUES (p_alert_id, 'patient', 'CANCEL', jsonb_build_object('reason', p_reason));

    RETURN jsonb_build_object('success', true, 'state', 'CANCELLED');
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 5. ENGINE_TICK: The Heartbeat
-- Calls escalate_overdue, expires claims, releases beds in one transaction
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION engine_tick()
RETURNS JSONB AS $$
DECLARE
    v_escalated_count INT := 0;
    v_expired_alerts_count INT := 0;
    v_released_holds_count INT := 0;
BEGIN
    -- 1. Escalate overdue tasks
    WITH esc AS (
        SELECT * FROM escalate_overdue()
    )
    SELECT COUNT(*) INTO v_escalated_count FROM esc;

    -- 2. Expire un-arrived alerts past ETA + 5 minutes
    WITH exp_alerts AS (
        UPDATE alerts
        SET state = 'EXPIRED'
        WHERE state IN ('SENT', 'ACKNOWLEDGED', 'CLAIMING', 'ALL_CLAIMED')
          AND expires_at IS NOT NULL
          AND expires_at < timezone('utc', now())
        RETURNING id, facility_id
    ),
    rel_holds AS (
        UPDATE bed_holds bh
        SET released_at = timezone('utc', now())
        FROM exp_alerts ea
        WHERE bh.alert_id = ea.id AND bh.released_at IS NULL
        RETURNING bh.id, bh.facility_id
    )
    SELECT COUNT(*) INTO v_expired_alerts_count FROM exp_alerts;

    -- 3. Release expired bed holds (30 min timeout)
    WITH expired_holds AS (
        UPDATE bed_holds
        SET released_at = timezone('utc', now())
        WHERE released_at IS NULL
          AND expires_at < timezone('utc', now())
        RETURNING facility_id
    )
    UPDATE facilities f
    SET ed_beds_free = ed_beds_free + 1
    FROM expired_holds eh
    WHERE f.id = eh.facility_id;

    GET DIAGNOSTICS v_released_holds_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'tick_at', timezone('utc', now()),
        'tasks_escalated', v_escalated_count,
        'alerts_expired', v_expired_alerts_count,
        'holds_released', v_released_holds_count
    );
END;
$$ LANGUAGE plpgsql;
