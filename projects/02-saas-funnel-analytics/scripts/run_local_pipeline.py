"""Build and validate the local DuckDB Bronze/Silver/Gold analytics pipeline."""

from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

import duckdb

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_ROOT / "data" / "raw"
DATABASE_PATH = PROJECT_ROOT / "data" / "warehouse" / "saas_funnel.duckdb"
GOLD_DIR = PROJECT_ROOT / "data" / "processed" / "gold"
SOURCE_FILES = {
    "bronze_users": "users.csv",
    "bronze_funnel_events": "funnel_events.csv",
    "bronze_subscriptions": "subscriptions.csv",
    "bronze_marketing_spend": "monthly_channel_spend.csv",
}
GOLD_TABLES = ("dim_users", "dim_date", "fact_funnel_milestones", "fact_channel_economics")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--as-of-date",
        default="2026-11-14",
        help="Date used to determine current churn status (default: 2026-11-14).",
    )
    parser.add_argument(
        "--gross-margin-pct",
        type=float,
        default=0.75,
        help="Assumed gross margin as a decimal for payback estimates (default: 0.75).",
    )
    return parser.parse_args()


def _sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _require_source_files() -> None:
    missing = [filename for filename in SOURCE_FILES.values() if not (RAW_DIR / filename).is_file()]
    if missing:
        names = ", ".join(missing)
        raise FileNotFoundError(f"Missing raw CSV file(s) in {RAW_DIR}: {names}. Run generate_saas_data.py first.")


def _load_bronze(connection: duckdb.DuckDBPyConnection) -> None:
    for table_name, filename in SOURCE_FILES.items():
        path = (RAW_DIR / filename).resolve()
        connection.execute(
            f"CREATE OR REPLACE TABLE {table_name} AS "
            f"SELECT * FROM READ_CSV_AUTO({_sql_string(str(path))}, HEADER = TRUE)"
        )


def _run_sql_file(connection: duckdb.DuckDBPyConnection, filename: str) -> None:
    sql_path = PROJECT_ROOT / "sql" / filename
    connection.execute(sql_path.read_text(encoding="utf-8"))


def _count(connection: duckdb.DuckDBPyConnection, query: str) -> int:
    return int(connection.execute(query).fetchone()[0])


def _validate(connection: duckdb.DuckDBPyConnection) -> dict[str, int]:
    counts = {
        "bronze_users": _count(connection, "SELECT COUNT(*) FROM bronze_users"),
        "bronze_funnel_events": _count(connection, "SELECT COUNT(*) FROM bronze_funnel_events"),
        "bronze_subscriptions": _count(connection, "SELECT COUNT(*) FROM bronze_subscriptions"),
        "bronze_marketing_spend": _count(connection, "SELECT COUNT(*) FROM bronze_marketing_spend"),
        "silver_users": _count(connection, "SELECT COUNT(*) FROM silver_users"),
        "silver_funnel_events": _count(connection, "SELECT COUNT(*) FROM silver_funnel_events"),
        "silver_subscriptions": _count(connection, "SELECT COUNT(*) FROM silver_subscriptions"),
        "silver_marketing_spend": _count(connection, "SELECT COUNT(*) FROM silver_marketing_spend"),
        "dim_users": _count(connection, "SELECT COUNT(*) FROM dim_users"),
        "dim_date": _count(connection, "SELECT COUNT(*) FROM dim_date"),
        "fact_funnel_milestones": _count(connection, "SELECT COUNT(*) FROM fact_funnel_milestones"),
        "fact_channel_economics": _count(connection, "SELECT COUNT(*) FROM fact_channel_economics"),
    }

    if counts["silver_users"] != counts["bronze_users"]:
        raise ValueError("Silver user deduplication changed the expected user count.")
    if counts["silver_funnel_events"] >= counts["bronze_funnel_events"]:
        raise ValueError("Expected duplicate funnel events to be removed in Silver.")
    if counts["dim_users"] != counts["silver_users"]:
        raise ValueError("dim_users must contain one row per Silver user.")
    if counts["fact_funnel_milestones"] != counts["silver_funnel_events"]:
        raise ValueError("Each valid Silver event should produce exactly one fact milestone.")
    if counts["dim_date"] != 730:
        raise ValueError(f"dim_date should cover 730 days from 2025-01-01 through 2026-12-31; got {counts['dim_date']}.")
    if counts["silver_marketing_spend"] != counts["bronze_marketing_spend"]:
        raise ValueError("Silver marketing-spend deduplication changed the expected source row count.")
    if counts["fact_channel_economics"] == 0:
        raise ValueError("No mature channel-economics cohorts were produced.")

    duplicate_user_stage_count = _count(
        connection,
        """SELECT COUNT(*) FROM (
            SELECT user_id, stage_order
            FROM fact_funnel_milestones
            GROUP BY user_id, stage_order
            HAVING COUNT(*) > 1
        )""",
    )
    null_channel_count = _count(connection, "SELECT COUNT(*) FROM silver_users WHERE acquisition_channel IS NULL")
    country_case_count = _count(connection, "SELECT COUNT(*) FROM silver_users WHERE country <> UPPER(country)")
    missing_dimension_users = _count(
        connection,
        """SELECT COUNT(*) FROM fact_funnel_milestones AS fact
        LEFT JOIN dim_users AS users USING (user_id)
        WHERE users.user_id IS NULL""",
    )
    invalid_stage_timestamps = _count(
        connection,
        """SELECT COUNT(*) FROM (
            SELECT
                event_timestamp,
                LAG(event_timestamp) OVER (PARTITION BY user_id ORDER BY stage_order) AS prior_timestamp
            FROM silver_funnel_events
        ) AS ordered_events
        WHERE prior_timestamp IS NOT NULL AND event_timestamp <= prior_timestamp""",
    )
    duplicate_spend_grains = _count(
        connection,
        """SELECT COUNT(*) FROM (
            SELECT spend_month, acquisition_channel
            FROM silver_marketing_spend
            GROUP BY spend_month, acquisition_channel
            HAVING COUNT(*) > 1
        )""",
    )
    duplicate_economics_grains = _count(
        connection,
        """SELECT COUNT(*) FROM (
            SELECT signup_month, acquisition_channel
            FROM fact_channel_economics
            GROUP BY signup_month, acquisition_channel
            HAVING COUNT(*) > 1
        )""",
    )
    invalid_economics = _count(
        connection,
        """SELECT COUNT(*) FROM fact_channel_economics
        WHERE marketing_spend < 0
           OR mature_signups < paid_users
           OR gross_margin_pct <= 0
           OR gross_margin_pct > 1
           OR (marketing_spend > 0 AND paid_users > 0 AND customer_acquisition_cost IS NULL)
           OR (customer_acquisition_cost IS NOT NULL AND customer_acquisition_cost < 0)
           OR (estimated_payback_months IS NOT NULL AND estimated_payback_months < 0)""",
    )
    immature_economics_cohorts = _count(
        connection,
        """SELECT COUNT(*) FROM fact_channel_economics
        WHERE signup_month > (
            SELECT DATE_TRUNC('month', as_of_date - INTERVAL 40 DAY) - INTERVAL 1 MONTH
            FROM pipeline_config
        )::DATE""",
    )

    if (
        duplicate_user_stage_count
        or null_channel_count
        or country_case_count
        or missing_dimension_users
        or invalid_stage_timestamps
        or duplicate_spend_grains
        or duplicate_economics_grains
        or invalid_economics
        or immature_economics_cohorts
    ):
        raise ValueError(
            "Silver/Gold quality checks failed: "
            f"duplicate_user_stages={duplicate_user_stage_count}, "
            f"null_channels={null_channel_count}, non_uppercase_countries={country_case_count}, "
            f"missing_dim_users={missing_dimension_users}, invalid_timestamps={invalid_stage_timestamps}, "
            f"duplicate_spend_grains={duplicate_spend_grains}, "
            f"duplicate_economics_grains={duplicate_economics_grains}, "
            f"invalid_economics={invalid_economics}, immature_economics_cohorts={immature_economics_cohorts}."
        )

    stage_rows = connection.execute(
        """SELECT stage_order, stage_name, COUNT(DISTINCT user_id) AS user_count
        FROM fact_funnel_milestones
        GROUP BY stage_order, stage_name
        ORDER BY stage_order"""
    ).fetchall()
    stage_counts = [int(row[2]) for row in stage_rows]
    if not all(previous > current for previous, current in zip(stage_counts, stage_counts[1:])):
        raise ValueError(f"Funnel stage counts should decrease at each stage; got {stage_counts}.")

    return counts


def _export_gold(connection: duckdb.DuckDBPyConnection) -> None:
    GOLD_DIR.mkdir(parents=True, exist_ok=True)
    order_by = {
        "dim_users": "user_id",
        "dim_date": '"date"',
        "fact_funnel_milestones": "user_id, stage_order",
        "fact_channel_economics": "signup_month, acquisition_channel",
    }
    for table_name in GOLD_TABLES:
        for extension, format_options in (
            ("csv", "FORMAT CSV, HEADER, DELIMITER ','"),
            ("parquet", "FORMAT PARQUET"),
        ):
            output_path = (GOLD_DIR / f"{table_name}.{extension}").resolve()
            output_path.unlink(missing_ok=True)
            connection.execute(
                f"COPY (SELECT * FROM {table_name} ORDER BY {order_by[table_name]}) "
                f"TO {_sql_string(str(output_path))} ({format_options})"
            )


def main() -> None:
    args = parse_args()
    try:
        if not 0 < args.gross_margin_pct <= 1:
            raise SystemExit("--gross-margin-pct must be greater than 0 and no more than 1")
        as_of_date = date.fromisoformat(args.as_of_date)
    except ValueError as error:
        raise SystemExit("--as-of-date must use YYYY-MM-DD format") from error

    _require_source_files()
    DATABASE_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(str(DATABASE_PATH))
    try:
        connection.execute(
            """CREATE OR REPLACE TEMP TABLE pipeline_config AS
            SELECT ?::DATE AS as_of_date, ?::DOUBLE AS gross_margin_pct""",
            [as_of_date, args.gross_margin_pct],
        )
        _load_bronze(connection)
        _run_sql_file(connection, "01_silver_cleaning.sql")
        _run_sql_file(connection, "02_gold_star_schema.sql")
        _run_sql_file(connection, "04_channel_economics.sql")
        counts = _validate(connection)
        _export_gold(connection)
    finally:
        connection.close()

    print("Local DuckDB pipeline completed successfully.")
    for table_name, row_count in counts.items():
        print(f"  {table_name}: {row_count:,} rows")
    print(f"Gold exports: {GOLD_DIR}")
    print(f"DuckDB database: {DATABASE_PATH}")


if __name__ == "__main__":
    main()
