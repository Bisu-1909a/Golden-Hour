-- Migration 11: The Engine in SQL (next_state, escalate_overdue, engine_tick, claim_task, cancel_alert)
-- GoldenHour Blueprint §6.1 / §07 / §8.3 / NIRMAN 2026

-- Helper functions for RLS & authorization
CREATE OR REPLACE FUNCTION auth_staff_facility_id()
RETURNS UUID AS $$
    SELECT facility_id FROM public.staff WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '';

CREATE OR REPLACE FUNCTION auth_staff_role()
RETURNS TEXT AS $$
    SELECT role::text FROM public.staff WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '';

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
    v_new_state alert_state;
    v_staff staff%ROWTYPE;
BEGIN
    SET search_path = '';

    SELECT * INTO v_alert FROM public.alerts WHERE id = p_alert_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Alert with id % not found', p_alert_id;
    END IF;

    -- Human caller identity must come from auth.uid()
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT * INTO v_staff FROM public.staff WHERE user_id = auth.uid();
    IF NOT FOUND OR v_staff.is_on_shift IS NOT TRUE THEN
        RAISE EXCEPTION 'Staff record not found or inactive';
    END IF;

    IF v_staff.facility_id IS DISTINCT FROM v_alert.facility_id THEN
        RAISE EXCEPTION 'Cross-facility access denied';
    END IF;

    -- Terminal states cannot transition
    IF v_alert.state IN ('CANCELLED', 'EXPIRED', 'CLOSED') THEN
        RETURN v_alert.state::text;
    END IF;

    IF p_action = 'ACKNOWLEDGE' THEN
        IF v_alert.state = 'SENT' THEN
            v_new_state := 'ACKNOWLEDGED';
            UPDATE public.alerts SET state = v_new_state, acknowledged_at = timezone('utc', now()) WHERE id = p_alert_id;
            INSERT INTO public.events (alert_id, actor_role, action, payload) VALUES (p_alert_id, v_staff.role, 'ACK', '{}'::jsonb);
        ELSE
            v_new_state := v_alert.state;
        END IF;

    ELSIF p_action = 'CHECK_CLAIM_PROGRESS' THEN
        SELECT NOT EXISTS(SELECT 1 FROM public.alert_tasks WHERE alert_id = p_alert_id AND state = 'OPEN')
        INTO v_all_tasks_claimed;

        IF v_all_tasks_claimed THEN
            v_new_state := 'ALL_CLAIMED';
            UPDATE public.alerts SET state = v_new_state, all_claimed_at = timezone('utc', now()) WHERE id = p_alert_id;
            INSERT INTO public.events (alert_id, actor_role, action, payload) VALUES (p_alert_id, v_staff.role, 'ALL_CLAIMED', '{}'::jsonb);
        ELSE
            IF v_alert.state = 'ACKNOWLEDGED' THEN
                v_new_state := 'CLAIMING';
                UPDATE public.alerts SET state = v_new_state WHERE id = p_alert_id;
            ELSE
                v_new_state := v_alert.state;
            END IF;
        END IF;

    ELSIF p_action = 'ARRIVED' THEN
        IF v_alert.state NOT IN ('ALL_CLAIMED', 'CLAIMING', 'ACKNOWLEDGED') THEN
            RAISE EXCEPTION 'Cannot mark arrived from state %', v_alert.state;
        END IF;
        v_new_state := 'ARRIVED';
        UPDATE public.alerts SET state = v_new_state, arrived_at = timezone('utc', now()) WHERE id = p_alert_id;
        INSERT INTO public.events (alert_id, actor_role, action, payload) VALUES (p_alert_id, v_staff.role, 'ARRIVED', '{}'::jsonb);

    ELSIF p_action = 'CLOSE' THEN
        IF v_alert.state != 'ARRIVED' THEN
            RAISE EXCEPTION 'Cannot close alert before arrival is confirmed';
        END IF;
        v_new_state := 'CLOSED';
        UPDATE public.alerts SET state = v_new_state, closed_at = timezone('utc', now()) WHERE id = p_alert_id;
        INSERT INTO public.events (alert_id, actor_role, action, payload) VALUES (p_alert_id, v_staff.role, 'CLOSED', '{}'::jsonb);

    ELSE
        RAISE EXCEPTION 'Illegal action % for alert state %', p_action, v_alert.state;
    END IF;

    RETURN v_new_state::text;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- -----------------------------------------------------------------------------
-- 2. CLAIM_TASK: Atomic compare-and-set claim with verified staff identity
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_task(
    p_task_id UUID,
    p_staff_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_task alert_tasks%ROWTYPE;
    v_staff staff%ROWTYPE;
    v_alert alerts%ROWTYPE;
BEGIN
    -- 1. Identity Verification: Must match authenticated user (auth.uid())
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Authentication required to claim tasks',
            'code', 'UNAUTHORIZED'
        );
    END IF;

    SELECT * INTO v_staff FROM public.staff WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Caller has no active staff record for authenticated user',
            'code', 'STAFF_NOT_FOUND'
        );
    END IF;

    IF p_staff_id IS NOT NULL AND v_staff.id <> p_staff_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Staff identity mismatch: p_staff_id does not match authenticated user',
            'code', 'FORBIDDEN'
        );
    END IF;

    -- 2. Verify task existence and facility isolation
    SELECT t.* INTO v_task FROM alert_tasks t WHERE t.id = p_task_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Task not found', 'code', 'TASK_NOT_FOUND');
    END IF;

    SELECT a.* INTO v_alert FROM alerts a WHERE a.id = v_task.alert_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Associated alert not found', 'code', 'ALERT_NOT_FOUND');
    END IF;

    IF v_staff.facility_id IS NOT NULL AND v_alert.facility_id IS NOT NULL AND v_staff.facility_id <> v_alert.facility_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cross-facility restriction: Staff cannot claim tasks for another hospital',
            'code', 'FACILITY_MISMATCH'
        );
    END IF;

    -- 3. Atomic compare-and-set: only updates if state is strictly 'OPEN'
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
            'claimed_at', v_task.claimed_at,
            'current_state', v_task.state
        );
    END IF;

    -- 4. Log to audit events table
    INSERT INTO events (alert_id, actor_id, actor_role, action, payload)
    VALUES (
        v_task.alert_id,
        v_staff.id,
        v_staff.role::text,
        'CLAIM',
        jsonb_build_object(
            'task_id', v_task.id,
            'team', v_task.team,
            'title', v_task.title,
            'staff_id', v_staff.id,
            'staff_name', v_staff.full_name
        )
    );

    -- 5. Queue chime notification to outbox
    INSERT INTO notification_outbox (alert_id, task_id, recipient_role, channel, payload)
    VALUES (
        v_task.alert_id,
        v_task.id,
        v_task.team::text,
        'in_app_chime',
        jsonb_build_object(
            'event', 'TASK_CLAIMED',
            'task_id', v_task.id,
            'title', v_task.title,
            'claimed_by_name', v_staff.full_name
        )
    );

    -- 6. Check if this completes all tasks
    PERFORM next_state(v_task.alert_id, 'CHECK_CLAIM_PROGRESS');

    RETURN jsonb_build_object(
        'success', true,
        'task', row_to_json(v_task)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

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
        RETURNING alert_tasks.id, alert_tasks.alert_id, alert_tasks.team::text, alert_tasks.title, alert_tasks.escalation_n
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 4. CANCEL_ALERT: Reversible cancel, verified bed hold release, idempotent
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_alert(
    p_alert_id UUID,
    p_reason TEXT DEFAULT 'changed_hospital',
    p_access_token UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_alert alerts%ROWTYPE;
    v_staff staff%ROWTYPE;
    v_beds_released INT := 0;
BEGIN
    SELECT * INTO v_alert FROM alerts WHERE id = p_alert_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Alert not found', 'code', 'ALERT_NOT_FOUND');
    END IF;

    -- 1. Idempotency: Already cancelled alerts return success without duplicate releases
    IF v_alert.state = 'CANCELLED' THEN
        RETURN jsonb_build_object(
            'success', true,
            'already_cancelled', true,
            'message', 'Alert has already been cancelled',
            'state', 'CANCELLED'
        );
    END IF;

    -- Cannot cancel after arrival or closure
    IF v_alert.state IN ('ARRIVED', 'CLOSED', 'EXPIRED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cannot cancel alert in state ' || v_alert.state,
            'code', 'INVALID_STATE_TRANSITION',
            'current_state', v_alert.state
        );
    END IF;

    -- 2. Authorization check
    IF auth.role() = 'service_role' THEN
        NULL;
    ELSIF auth.uid() IS NOT NULL THEN
        SELECT * INTO v_staff FROM public.staff WHERE user_id = auth.uid();
        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Staff record not found for authenticated user',
                'code', 'FORBIDDEN'
            );
        END IF;
        IF v_staff.facility_id IS DISTINCT FROM v_alert.facility_id THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Staff from another facility cannot cancel this alert',
                'code', 'FORBIDDEN'
            );
        END IF;
    ELSE
        -- Patient caller: verify access_token
        IF p_access_token IS NULL OR p_access_token <> v_alert.access_token THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Valid alert access_token required for patient cancellation',
                'code', 'UNAUTHORIZED'
            );
        END IF;
    END IF;

    -- 3. Atomic transition to CANCELLED
    UPDATE alerts
    SET state = 'CANCELLED',
        cancel_reason = p_reason::cancel_reason
    WHERE id = p_alert_id
      AND state NOT IN ('CANCELLED', 'ARRIVED', 'CLOSED', 'EXPIRED');

    IF NOT FOUND THEN
SELECT * INTO v_alert FROM public.alerts WHERE id = p_alert_id FOR UPDATE;
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Concurrent state transition detected',
            'current_state', v_alert.state
        );
    END IF;

    -- 4. Cancel all open or escalated tasks
    UPDATE alert_tasks
    SET state = 'DONE',
        done_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    WHERE alert_id = p_alert_id
      AND state IN ('OPEN', 'ESCALATED');

    -- 5. Release bed hold and ONLY increment facility bed count IF a hold was actually active
    WITH released AS (
        UPDATE bed_holds
        SET released_at = timezone('utc', now())
        WHERE alert_id = p_alert_id AND released_at IS NULL
        RETURNING facility_id
    )
    UPDATE facilities f
    SET ed_beds_free = LEAST(f.ed_beds_total, f.ed_beds_free + 1)
    FROM released r
    WHERE f.id = r.facility_id;

    GET DIAGNOSTICS v_beds_released = ROW_COUNT;

    -- 6. Log cancellation to ledger
    INSERT INTO cancellations (alert_id, reason, actor_role)
    VALUES (p_alert_id, p_reason, COALESCE(v_staff.role::text, 'patient'));

    -- 7. Log event
    INSERT INTO events (alert_id, actor_role, action, payload)
    VALUES (
        p_alert_id,
        COALESCE(v_staff.role::text, 'patient'),
        'CANCEL',
        jsonb_build_object(
            'reason', p_reason,
            'bed_released', (v_beds_released > 0)
        )
    );

    -- 8. Queue outbox notification to supervisor wall
    INSERT INTO notification_outbox (alert_id, recipient_role, channel, payload)
    VALUES (
        p_alert_id,
        'supervisor',
        'supervisor_wall',
        jsonb_build_object(
            'event', 'ALERT_CANCELLED',
            'reason', p_reason,
            'bed_released', (v_beds_released > 0)
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'state', 'CANCELLED',
        'bed_released', (v_beds_released > 0)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- -----------------------------------------------------------------------------
-- 5. ENGINE_TICK: The Heartbeat
-- Calls escalate_overdue, expires claims, releases beds in one transaction
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION engine_tick()
RETURNS JSONB AS $
DECLARE
    v_escalated_count INT := 0;
    v_expired_alerts_count INT := 0;
    v_released_holds_count INT := 0;
BEGIN
    SET search_path = public;

    -- 1. Escalate overdue tasks
    WITH esc AS (
        SELECT * FROM escalate_overdue()
    )
    SELECT COUNT(*) INTO v_escalated_count FROM esc;

    -- 2. Expire un-arrived alerts past ETA + 5 minutes
    UPDATE alerts
    SET state = 'EXPIRED'
    WHERE state IN ('SENT', 'ACKNOWLEDGED', 'CLAIMING', 'ALL_CLAIMED')
      AND expires_at IS NOT NULL
      AND expires_at < timezone('utc', now());
    GET DIAGNOSTICS v_expired_alerts_count = ROW_COUNT;

    INSERT INTO events (alert_id, actor_role, action, payload)
    SELECT a.id, 'system', 'ALERT_EXPIRED', jsonb_build_object('expired_at', timezone('utc', now()))
    FROM alerts a
    WHERE a.state = 'EXPIRED'
      AND a.expires_at IS NOT NULL
      AND a.expires_at < timezone('utc', now());

    -- 3. Release expired-alert holds and timed-out holds without double release
    WITH rel_alert_holds AS (
        UPDATE bed_holds bh
        SET released_at = timezone('utc', now())
        WHERE bh.released_at IS NULL
          AND bh.alert_id IN (
              SELECT id FROM alerts
              WHERE state = 'EXPIRED'
                AND expires_at IS NOT NULL
                AND expires_at < timezone('utc', now())
          )
        RETURNING bh.facility_id
    ),
    rel_timeout_holds AS (
        UPDATE bed_holds
        SET released_at = timezone('utc', now())
        WHERE released_at IS NULL
          AND expires_at < timezone('utc', now())
        RETURNING facility_id
    ),
    all_released AS (
        SELECT facility_id FROM rel_alert_holds
        UNION ALL
        SELECT facility_id FROM rel_timeout_holds
    ),
    agg_released AS (
        SELECT facility_id, COUNT(*) AS cnt
        FROM all_released
        GROUP BY facility_id
    ),
    facility_update AS (
        UPDATE facilities f
        SET ed_beds_free = LEAST(f.ed_beds_total, f.ed_beds_free + ar.cnt::int)
        FROM agg_released ar
        WHERE f.id = ar.facility_id
    )
    SELECT COUNT(*) INTO v_released_holds_count FROM all_released;

    RETURN jsonb_build_object(
        'success', true,
        'tick_at', timezone('utc', now()),
        'tasks_escalated', v_escalated_count,
        'alerts_expired', v_expired_alerts_count,
        'holds_released', v_released_holds_count
    );
END;
$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- -----------------------------------------------------------------------------
-- 6. PRIVILEGED GRANTS & FUNCTION PERMISSIONS
-- -----------------------------------------------------------------------------
-- Restrict engine heartbeat and overdue escalators to background service_role only
REVOKE EXECUTE ON FUNCTION engine_tick() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION escalate_overdue() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION next_state(UUID, TEXT) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION engine_tick() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION escalate_overdue() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION next_state(UUID, TEXT) TO authenticated, postgres;

-- claim_task: authenticated staff and service_role only
REVOKE EXECUTE ON FUNCTION claim_task(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION claim_task(UUID, UUID) TO authenticated, service_role, postgres;

-- cancel_alert: anon (patient token), authenticated (staff), and service_role
GRANT EXECUTE ON FUNCTION cancel_alert(UUID, TEXT, UUID) TO anon, authenticated, service_role, postgres;
