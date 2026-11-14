PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS model_rates (
    model TEXT PRIMARY KEY,
    input_usd_per_million REAL NOT NULL CHECK (input_usd_per_million >= 0),
    output_usd_per_million REAL NOT NULL CHECK (output_usd_per_million >= 0)
);

CREATE TABLE IF NOT EXISTS department_rates (
    department TEXT PRIMARY KEY,
    loaded_labor_usd_per_hour REAL NOT NULL CHECK (loaded_labor_usd_per_hour >= 0)
);

CREATE TABLE IF NOT EXISTS usage_events (
    event_id TEXT PRIMARY KEY,
    occurred_at TEXT NOT NULL,
    department TEXT NOT NULL REFERENCES department_rates(department),
    workflow TEXT NOT NULL,
    user_id TEXT NOT NULL,
    model TEXT NOT NULL REFERENCES model_rates(model),
    input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
    output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
    outcome TEXT NOT NULL CHECK (outcome IN ('success', 'partial', 'failed')),
    minutes_saved REAL NOT NULL CHECK (minutes_saved >= 0),
    review_minutes REAL NOT NULL CHECK (review_minutes >= 0)
);

CREATE INDEX IF NOT EXISTS idx_usage_events_occurred_at ON usage_events(occurred_at);
CREATE INDEX IF NOT EXISTS idx_usage_events_department_workflow ON usage_events(department, workflow);
