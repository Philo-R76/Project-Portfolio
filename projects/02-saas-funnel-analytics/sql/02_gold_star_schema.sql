-- Gold layer: conformed dimensions and one row per user per completed stage.

CREATE OR REPLACE TABLE dim_date AS
SELECT
    calendar_date::DATE AS date,
    EXTRACT(YEAR FROM calendar_date)::INTEGER AS year,
    EXTRACT(QUARTER FROM calendar_date)::INTEGER AS quarter,
    EXTRACT(MONTH FROM calendar_date)::INTEGER AS month_number,
    STRFTIME(calendar_date, '%B') AS month_name,
    DATE_TRUNC('month', calendar_date)::DATE AS month_start
FROM GENERATE_SERIES(
    DATE '2025-01-01',
    DATE '2026-12-31',
    INTERVAL 1 DAY
) AS dates(calendar_date);

CREATE OR REPLACE TABLE dim_users AS
WITH latest_subscription AS (
    SELECT user_id, plan_tier, churn_date
    FROM silver_subscriptions
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY user_id
        ORDER BY start_date DESC, sub_id DESC
    ) = 1
)
SELECT
    users.user_id,
    users.signup_date,
    users.acquisition_channel,
    users.company_size,
    users.country,
    subscription.plan_tier AS current_plan_tier,
    COALESCE(
        subscription.churn_date <= (SELECT as_of_date FROM pipeline_config),
        FALSE
    ) AS is_churned
FROM silver_users AS users
LEFT JOIN latest_subscription AS subscription USING (user_id);

CREATE OR REPLACE TABLE fact_funnel_milestones AS
WITH milestones AS (
    SELECT
        events.*,
        LAG(events.event_timestamp) OVER (
            PARTITION BY events.user_id
            ORDER BY events.stage_order
        ) AS previous_stage_timestamp
    FROM silver_funnel_events AS events
)
SELECT
    milestones.user_id,
    milestones.stage_order,
    milestones.event_name AS stage_name,
    CAST(milestones.event_timestamp AS DATE) AS stage_date,
    DATE_DIFF('day', users.signup_date, CAST(milestones.event_timestamp AS DATE)) AS days_from_signup,
    CASE
        WHEN milestones.previous_stage_timestamp IS NULL THEN NULL
        ELSE DATE_DIFF(
            'day',
            CAST(milestones.previous_stage_timestamp AS DATE),
            CAST(milestones.event_timestamp AS DATE)
        )
    END AS days_from_previous_stage,
    CASE
        WHEN milestones.event_name = 'Upgraded_to_Paid' THEN COALESCE(subscriptions.mrr_amount, 0)
        ELSE 0
    END AS mrr_value
FROM milestones
JOIN silver_users AS users USING (user_id)
LEFT JOIN silver_subscriptions AS subscriptions USING (user_id);
