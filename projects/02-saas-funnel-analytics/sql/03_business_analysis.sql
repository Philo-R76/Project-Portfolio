-- Reproducible executive analysis queries for the local Gold model.
-- Run after 01_silver_cleaning.sql and 02_gold_star_schema.sql.

-- 1) Stage drop-off, step conversion, and conversion from signup.
WITH stage_counts AS (
    SELECT
        stage_order,
        stage_name,
        COUNT(DISTINCT user_id) AS users
    FROM fact_funnel_milestones
    GROUP BY stage_order, stage_name
),
stage_rates AS (
    SELECT
        *,
        LAG(users) OVER (ORDER BY stage_order) AS prior_stage_users,
        FIRST_VALUE(users) OVER (ORDER BY stage_order) AS signup_users
    FROM stage_counts
)
SELECT
    stage_order,
    stage_name,
    users,
    signup_users - users AS users_lost_from_signup,
    ROUND(100.0 * users / NULLIF(signup_users, 0), 1) AS signup_conversion_pct,
    ROUND(100.0 * users / NULLIF(prior_stage_users, 0), 1) AS step_conversion_pct
FROM stage_rates
ORDER BY stage_order;

-- 2) Channel conversion for signup cohorts with a full 40-day observation window.
-- The maximum generated stage delay is 4 + 6 + 10 + 20 = 40 days.
-- See fact_channel_economics for CAC and payback estimates based on synthetic spend assumptions.
WITH mature_signups AS (
    SELECT user_id, acquisition_channel
    FROM dim_users
    WHERE signup_date <= DATE '2026-10-05'
),
paid_users AS (
    SELECT DISTINCT user_id
    FROM fact_funnel_milestones
    WHERE stage_order = 5
)
SELECT
    signups.acquisition_channel,
    COUNT(*) AS mature_signups,
    COUNT(*) FILTER (WHERE paid.user_id IS NOT NULL) AS paid_users,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE paid.user_id IS NOT NULL) / NULLIF(COUNT(*), 0),
        1
    ) AS paid_conversion_pct
FROM mature_signups AS signups
LEFT JOIN paid_users AS paid USING (user_id)
GROUP BY signups.acquisition_channel
ORDER BY paid_conversion_pct DESC, mature_signups DESC;

-- 3) Average time from the previous milestone by company segment.
SELECT
    events.stage_order,
    events.stage_name,
    users.company_size,
    COUNT(*) AS milestone_count,
    ROUND(AVG(events.days_from_previous_stage), 1) AS avg_days_from_previous_stage
FROM fact_funnel_milestones AS events
JOIN dim_users AS users USING (user_id)
WHERE events.stage_order > 1
GROUP BY events.stage_order, events.stage_name, users.company_size
ORDER BY events.stage_order, users.company_size;

-- 4) Active paid ARR and churn by channel (descriptive, not marketing ROI).
SELECT
    users.acquisition_channel,
    COUNT(*) AS paid_users,
    COUNT(*) FILTER (WHERE users.is_churned) AS churned_paid_users,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE users.is_churned) / NULLIF(COUNT(*), 0),
        1
    ) AS paid_churn_pct,
    ROUND(SUM(events.mrr_value) FILTER (WHERE NOT users.is_churned) * 12, 2) AS active_arr
FROM fact_funnel_milestones AS events
JOIN dim_users AS users USING (user_id)
WHERE events.stage_order = 5
GROUP BY users.acquisition_channel
ORDER BY active_arr DESC;
