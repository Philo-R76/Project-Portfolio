-- Overall and monthly economics. A negative ROI proxy indicates modeled labor
-- capacity value is below API spend, not a proven cash loss.
WITH event_economics AS (
    SELECT
        e.*,
        e.input_tokens * m.input_usd_per_million / 1000000.0
            + e.output_tokens * m.output_usd_per_million / 1000000.0 AS api_cost_usd,
        (e.minutes_saved - e.review_minutes) / 60.0
            * d.loaded_labor_usd_per_hour AS labor_capacity_value_usd
    FROM usage_events AS e
    JOIN model_rates AS m ON m.model = e.model
    JOIN department_rates AS d ON d.department = e.department
)
SELECT
    COUNT(*) AS tasks,
    ROUND(SUM(api_cost_usd), 2) AS api_cost_usd,
    ROUND(SUM(labor_capacity_value_usd), 2) AS labor_capacity_value_usd,
    ROUND(100.0 * (SUM(labor_capacity_value_usd) - SUM(api_cost_usd))
        / NULLIF(SUM(api_cost_usd), 0), 1) AS roi_proxy_pct,
    ROUND(100.0 * AVG(CASE WHEN outcome = 'success' THEN 1.0 ELSE 0.0 END), 1)
        AS successful_task_rate_pct
FROM event_economics;

WITH event_economics AS (
    SELECT
        e.*,
        e.input_tokens * m.input_usd_per_million / 1000000.0
            + e.output_tokens * m.output_usd_per_million / 1000000.0 AS api_cost_usd,
        (e.minutes_saved - e.review_minutes) / 60.0
            * d.loaded_labor_usd_per_hour AS labor_capacity_value_usd
    FROM usage_events AS e
    JOIN model_rates AS m ON m.model = e.model
    JOIN department_rates AS d ON d.department = e.department
)
SELECT
    strftime('%Y-%m', occurred_at) AS month,
    COUNT(*) AS tasks,
    ROUND(SUM(api_cost_usd), 2) AS api_cost_usd,
    ROUND(SUM(labor_capacity_value_usd), 2) AS labor_capacity_value_usd,
    ROUND(SUM(labor_capacity_value_usd) - SUM(api_cost_usd), 2) AS modeled_net_value_usd,
    ROUND(100.0 * (SUM(labor_capacity_value_usd) - SUM(api_cost_usd))
        / NULLIF(SUM(api_cost_usd), 0), 1) AS roi_proxy_pct,
    ROUND(100.0 * SUM(CASE WHEN outcome = 'success' THEN 1 ELSE 0 END) / COUNT(*), 1)
        AS successful_task_rate_pct
FROM event_economics
GROUP BY strftime('%Y-%m', occurred_at)
ORDER BY month;

-- Department scorecard: use value, spend, task count, and success together.
WITH event_economics AS (
    SELECT
        e.*,
        e.input_tokens * m.input_usd_per_million / 1000000.0
            + e.output_tokens * m.output_usd_per_million / 1000000.0 AS api_cost_usd,
        (e.minutes_saved - e.review_minutes) / 60.0
            * d.loaded_labor_usd_per_hour AS labor_capacity_value_usd
    FROM usage_events AS e
    JOIN model_rates AS m ON m.model = e.model
    JOIN department_rates AS d ON d.department = e.department
)
SELECT
    department,
    COUNT(*) AS tasks,
    ROUND(SUM(api_cost_usd), 2) AS api_cost_usd,
    ROUND(SUM(labor_capacity_value_usd), 2) AS labor_capacity_value_usd,
    ROUND(100.0 * (SUM(labor_capacity_value_usd) - SUM(api_cost_usd))
        / NULLIF(SUM(api_cost_usd), 0), 1) AS roi_proxy_pct,
    ROUND(AVG(CASE WHEN outcome = 'success' THEN 1.0 ELSE 0.0 END) * 100, 1)
        AS successful_task_rate_pct
FROM event_economics
GROUP BY department
ORDER BY roi_proxy_pct DESC;

-- Workflow opportunity: expose workflows with high spend or review burden.
WITH event_economics AS (
    SELECT
        e.*,
        e.input_tokens * m.input_usd_per_million / 1000000.0
            + e.output_tokens * m.output_usd_per_million / 1000000.0 AS api_cost_usd,
        (e.minutes_saved - e.review_minutes) / 60.0
            * d.loaded_labor_usd_per_hour AS labor_capacity_value_usd
    FROM usage_events AS e
    JOIN model_rates AS m ON m.model = e.model
    JOIN department_rates AS d ON d.department = e.department
)
SELECT
    department,
    workflow,
    COUNT(*) AS tasks,
    ROUND(AVG(api_cost_usd), 4) AS avg_api_cost_per_task_usd,
    ROUND(AVG(minutes_saved), 2) AS avg_minutes_saved,
    ROUND(AVG(review_minutes), 2) AS avg_review_minutes,
    ROUND(100.0 * AVG(CASE WHEN outcome = 'success' THEN 1.0 ELSE 0.0 END), 1)
        AS successful_task_rate_pct,
    ROUND(100.0 * (SUM(labor_capacity_value_usd) - SUM(api_cost_usd))
        / NULLIF(SUM(api_cost_usd), 0), 1) AS roi_proxy_pct
FROM event_economics
GROUP BY department, workflow
HAVING COUNT(*) >= 30
ORDER BY roi_proxy_pct DESC;

-- Model comparison; a model's ROI is not a quality-adjusted causal comparison.
WITH event_economics AS (
    SELECT
        e.*,
        e.input_tokens * m.input_usd_per_million / 1000000.0
            + e.output_tokens * m.output_usd_per_million / 1000000.0 AS api_cost_usd,
        (e.minutes_saved - e.review_minutes) / 60.0
            * d.loaded_labor_usd_per_hour AS labor_capacity_value_usd
    FROM usage_events AS e
    JOIN model_rates AS m ON m.model = e.model
    JOIN department_rates AS d ON d.department = e.department
)
SELECT
    model,
    COUNT(*) AS tasks,
    ROUND(AVG(api_cost_usd), 4) AS avg_api_cost_per_task_usd,
    ROUND(AVG(CASE WHEN outcome = 'success' THEN 1.0 ELSE 0.0 END) * 100, 1)
        AS successful_task_rate_pct,
    ROUND(100.0 * (SUM(labor_capacity_value_usd) - SUM(api_cost_usd))
        / NULLIF(SUM(api_cost_usd), 0), 1) AS roi_proxy_pct
FROM event_economics
GROUP BY model
ORDER BY roi_proxy_pct DESC;

-- Spend concentration by user (top 10); useful for adoption and governance checks.
WITH event_costs AS (
    SELECT
        e.user_id,
        e.department,
        e.input_tokens * m.input_usd_per_million / 1000000.0
            + e.output_tokens * m.output_usd_per_million / 1000000.0 AS api_cost_usd
    FROM usage_events AS e
    JOIN model_rates AS m ON m.model = e.model
),
user_spend AS (
    SELECT user_id, department, SUM(api_cost_usd) AS spend_usd
    FROM event_costs
    GROUP BY user_id, department
)
SELECT
    user_id,
    department,
    ROUND(spend_usd, 2) AS spend_usd,
    ROUND(100.0 * spend_usd / NULLIF((SELECT SUM(spend_usd) FROM user_spend), 0), 2)
        AS share_of_total_spend_pct
FROM user_spend
ORDER BY spend_usd DESC
LIMIT 10;
