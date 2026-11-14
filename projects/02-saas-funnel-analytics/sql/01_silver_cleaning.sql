-- Silver layer: typed, standardized, deduplicated, and progression-validated data.

CREATE OR REPLACE TABLE silver_users AS
SELECT
    CAST(user_id AS VARCHAR) AS user_id,
    CAST(signup_date AS DATE) AS signup_date,
    COALESCE(NULLIF(TRIM(CAST(acquisition_channel AS VARCHAR)), ''), 'Unknown') AS acquisition_channel,
    COALESCE(NULLIF(TRIM(CAST(company_size AS VARCHAR)), ''), 'Unknown') AS company_size,
    UPPER(TRIM(CAST(country AS VARCHAR))) AS country
FROM bronze_users
WHERE user_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY signup_date) = 1;

CREATE OR REPLACE TABLE silver_subscriptions AS
SELECT
    CAST(sub_id AS VARCHAR) AS sub_id,
    CAST(user_id AS VARCHAR) AS user_id,
    CAST(plan_tier AS VARCHAR) AS plan_tier,
    CAST(mrr_amount AS DECIMAL(12, 2)) AS mrr_amount,
    CAST(start_date AS DATE) AS start_date,
    CAST(churn_date AS DATE) AS churn_date
FROM bronze_subscriptions
WHERE sub_id IS NOT NULL
  AND user_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY sub_id ORDER BY start_date) = 1;

CREATE OR REPLACE TABLE silver_funnel_events AS
WITH stage_mapped AS (
    SELECT
        CAST(event_id AS VARCHAR) AS event_id,
        CAST(user_id AS VARCHAR) AS user_id,
        CAST(event_name AS VARCHAR) AS event_name,
        CAST(event_timestamp AS TIMESTAMP) AS event_timestamp,
        CASE CAST(event_name AS VARCHAR)
            WHEN 'Account_Created' THEN 1
            WHEN 'Workspace_Setup' THEN 2
            WHEN 'Team_Invited' THEN 3
            WHEN 'First_Integration' THEN 4
            WHEN 'Upgraded_to_Paid' THEN 5
        END AS stage_order
    FROM bronze_funnel_events
    WHERE event_id IS NOT NULL
      AND user_id IS NOT NULL
),
ranked_events AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, event_name
            ORDER BY event_timestamp, event_id
        ) AS duplicate_rank
    FROM stage_mapped
    WHERE stage_order IS NOT NULL
),
deduplicated_events AS (
    SELECT event_id, user_id, event_name, event_timestamp, stage_order
    FROM ranked_events
    WHERE duplicate_rank = 1
),
valid_progression AS (
    SELECT current_event.*
    FROM deduplicated_events AS current_event
    WHERE (
        SELECT COUNT(DISTINCT prior_event.stage_order)
        FROM deduplicated_events AS prior_event
        WHERE prior_event.user_id = current_event.user_id
          AND prior_event.stage_order < current_event.stage_order
          AND prior_event.event_timestamp < current_event.event_timestamp
    ) = current_event.stage_order - 1
)
SELECT event_id, user_id, event_name, event_timestamp, stage_order
FROM valid_progression;

CREATE OR REPLACE TABLE silver_marketing_spend AS
SELECT
        CAST(spend_id AS VARCHAR) AS spend_id,
        CAST(spend_month AS DATE) AS spend_month,
        COALESCE(NULLIF(TRIM(CAST(acquisition_channel AS VARCHAR)), ''), 'Unknown') AS acquisition_channel,
        CAST(campaign_name AS VARCHAR) AS campaign_name,
        CAST(spend_amount AS DECIMAL(14, 2)) AS spend_amount,
        UPPER(CAST(currency AS VARCHAR)) AS currency,
        CAST(spend_source AS VARCHAR) AS spend_source
FROM bronze_marketing_spend
WHERE spend_id IS NOT NULL
    AND spend_month IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
        PARTITION BY spend_id
        ORDER BY spend_month, acquisition_channel
) = 1;
