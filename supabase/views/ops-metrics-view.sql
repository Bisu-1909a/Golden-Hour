-- View: ops_metrics_view
-- GoldenHour Blueprint §6.3 / NIRMAN 2026
-- Rolling metrics for ops wall strip and presentation slides

CREATE OR REPLACE VIEW ops_metrics_view AS
SELECT 
    f.id AS facility_id,
    f.name AS facility_name,
    COUNT(a.id) AS total_alerts_today,
    COUNT(CASE WHEN a.state = 'ALL_CLAIMED' OR a.state = 'ARRIVED' OR a.state = 'CLOSED' THEN 1 END) AS successful_alerts,
    COUNT(CASE WHEN a.state = 'CANCELLED' THEN 1 END) AS cancelled_alerts,
    ROUND(
        COUNT(CASE WHEN a.state = 'CANCELLED' THEN 1 END)::NUMERIC / 
        GREATEST(1, COUNT(a.id)) * 100, 
        1
    ) AS cancellation_rate_pct,
    COUNT(CASE WHEN at.escalated_at IS NOT NULL THEN 1 END) AS total_escalated_tasks,
    -- Median time-to-first-claim in seconds
    COALESCE(
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (at.claimed_at - a.created_at))),
        45
    )::INT AS median_seconds_to_claim
FROM facilities f
LEFT JOIN alerts a ON a.facility_id = f.id AND a.created_at >= timezone('utc', now() - INTERVAL '24 hours')
LEFT JOIN alert_tasks at ON at.alert_id = a.id
GROUP BY f.id, f.name;
