-- Gold channel-economics fact at mature signup-month/channel grain.
-- Marketing spend values are synthetic assumptions, not actual media invoices.
-- A complete signup month is included only after its full 40-day conversion window.
-- Gross-margin payback is an estimate using the explicit pipeline configuration.

CREATE OR REPLACE TABLE fact_channel_economics AS
WITH config AS (
    SELECT
        as_of_date,
        gross_margin_pct,
        (
            DATE_TRUNC('month', as_of_date - INTERVAL 40 DAY) - INTERVAL 1 MONTH
        )::DATE AS mature_through_month
    FROM pipeline_config
),
mature_cohort_users AS (
    SELECT
        DATE_TRUNC('month', users.signup_date)::DATE AS signup_month,
        users.acquisition_channel,
        users.user_id,
        users.is_churned
    FROM dim_users AS users
    CROSS JOIN config
    WHERE DATE_TRUNC('month', users.signup_date)::DATE <= config.mature_through_month
),
cohort_signups AS (
    SELECT
        signup_month,
        acquisition_channel,
        COUNT(DISTINCT user_id) AS mature_signups
    FROM mature_cohort_users
    GROUP BY signup_month, acquisition_channel
),
cohort_paid AS (
    SELECT
        cohort_users.signup_month,
        cohort_users.acquisition_channel,
        COUNT(DISTINCT milestones.user_id) AS paid_users,
        COUNT(DISTINCT milestones.user_id) FILTER (WHERE NOT cohort_users.is_churned) AS active_paid_users,
        COUNT(DISTINCT milestones.user_id) FILTER (WHERE cohort_users.is_churned) AS churned_paid_users,
        AVG(milestones.mrr_value) AS average_paid_mrr,
        SUM(milestones.mrr_value) FILTER (WHERE NOT cohort_users.is_churned) AS active_mrr
    FROM mature_cohort_users AS cohort_users
    LEFT JOIN fact_funnel_milestones AS milestones
        ON milestones.user_id = cohort_users.user_id
       AND milestones.stage_order = 5
    GROUP BY cohort_users.signup_month, cohort_users.acquisition_channel
),
cohort_spend AS (
    SELECT
        spend_month AS signup_month,
        acquisition_channel,
        SUM(spend_amount)::DECIMAL(14, 2) AS marketing_spend,
        STRING_AGG(DISTINCT spend_source, ', ') AS spend_source,
        STRING_AGG(DISTINCT currency, ', ') AS currency
    FROM silver_marketing_spend
    GROUP BY spend_month, acquisition_channel
),
economics AS (
    SELECT
        signups.signup_month,
        signups.acquisition_channel,
        signups.mature_signups,
        COALESCE(paid.paid_users, 0) AS paid_users,
        COALESCE(paid.active_paid_users, 0) AS active_paid_users,
        COALESCE(paid.churned_paid_users, 0) AS churned_paid_users,
        COALESCE(spend.marketing_spend, 0)::DECIMAL(14, 2) AS marketing_spend,
        paid.average_paid_mrr,
        COALESCE(paid.active_mrr, 0)::DECIMAL(14, 2) AS active_mrr,
        spend.spend_source,
        spend.currency,
        config.as_of_date,
        config.mature_through_month,
        config.gross_margin_pct
    FROM cohort_signups AS signups
    LEFT JOIN cohort_paid AS paid USING (signup_month, acquisition_channel)
    LEFT JOIN cohort_spend AS spend USING (signup_month, acquisition_channel)
    CROSS JOIN config
)
SELECT
    signup_month,
    acquisition_channel,
    mature_signups,
    paid_users,
    active_paid_users,
    churned_paid_users,
    marketing_spend,
    CASE
        WHEN mature_signups = 0 THEN NULL
        ELSE 100.0 * paid_users / mature_signups
    END AS mature_paid_conversion_pct,
    CASE
        WHEN marketing_spend > 0 AND paid_users > 0 THEN marketing_spend / paid_users
        ELSE NULL
    END AS customer_acquisition_cost,
    average_paid_mrr,
    gross_margin_pct,
    CASE
        WHEN marketing_spend > 0
         AND paid_users > 0
         AND average_paid_mrr > 0
         AND gross_margin_pct > 0
        THEN (marketing_spend / paid_users) / (average_paid_mrr * gross_margin_pct)
        ELSE NULL
    END AS estimated_payback_months,
    active_mrr * 12 AS active_arr,
    CASE
        WHEN paid_users = 0 THEN NULL
        ELSE 100.0 * churned_paid_users / paid_users
    END AS paid_churn_pct,
    spend_source,
    currency,
    as_of_date,
    mature_through_month
FROM economics;
