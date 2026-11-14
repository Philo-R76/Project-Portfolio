"""Generate reproducible synthetic SaaS funnel data for the portfolio project.

Run from this directory or any working directory:
    python scripts/generate_saas_data.py

The generated CSVs are written to data/raw/ relative to the project root.
"""

from __future__ import annotations

import argparse
from datetime import date, datetime, time, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
from faker import Faker

PROJECT_ROOT = Path(__file__).resolve().parents[1]
AS_OF_DATE = date(2026, 11, 14)
FUNNEL_STAGES = (
    "Account_Created",
    "Workspace_Setup",
    "Team_Invited",
    "First_Integration",
    "Upgraded_to_Paid",
)
ACQUISITION_CHANNELS = ("Organic", "Paid Search", "LinkedIn", "Referral")
COMPANY_SIZES = ("SMB", "Mid-Market", "Enterprise")
COUNTRIES = (
    "United States",
    "Canada",
    "United Kingdom",
    "Australia",
    "Germany",
    "France",
    "India",
    "Singapore",
    "Netherlands",
    "Brazil",
)
CHANNEL_SPEND_ASSUMPTIONS = {
    "Organic": (9_500.0, "SEO and content"),
    "Paid Search": (16_000.0, "Paid search campaigns"),
    "LinkedIn": (12_000.0, "LinkedIn demand generation"),
    "Referral": (3_500.0, "Referral program"),
    "Unknown": (0.0, "Unattributed; no assigned spend"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--users", type=int, default=5_000, help="Number of users to generate (default: 5000).")
    parser.add_argument("--seed", type=int, default=42, help="Random seed for reproducible output (default: 42).")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "data" / "raw",
        help="Output directory for the CSV files (default: project data/raw).",
    )
    return parser.parse_args()


def generate_users(count: int, rng: np.random.Generator, fake: Faker) -> pd.DataFrame:
    start = date(2025, 1, 1)
    signup_span = (AS_OF_DATE - start).days
    signup_dates = [start + timedelta(days=int(offset)) for offset in rng.integers(0, signup_span + 1, count)]
    channels = rng.choice(ACQUISITION_CHANNELS, size=count, p=(0.38, 0.28, 0.20, 0.14)).astype(object)
    null_count = round(count * 0.02)
    if null_count:
        channels[rng.choice(count, size=null_count, replace=False)] = None

    countries = [fake.random_element(COUNTRIES) for _ in range(count)]
    # Vary case deliberately; the Silver transformation should normalize it.
    for index in rng.choice(count, size=round(count * 0.12), replace=False):
        countries[index] = countries[index].lower()

    return pd.DataFrame(
        {
            "user_id": [f"U{index:05d}" for index in range(1, count + 1)],
            "signup_date": signup_dates,
            "acquisition_channel": channels,
            "company_size": rng.choice(COMPANY_SIZES, size=count, p=(0.62, 0.28, 0.10)),
            "country": countries,
        }
    )


def _event_timestamp(day: date, rng: np.random.Generator) -> datetime:
    return datetime.combine(day, time(9, 0)) + timedelta(minutes=int(rng.integers(0, 12 * 60)))


def generate_events(users: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    """Create ordered, progressively smaller funnel cohorts and intentional duplicates."""
    # Conditional conversion probabilities create visible drop-off at every step.
    conditional_conversion = (0.95, 0.90, 0.80, 0.65)
    stage_delay_days = ((1, 4), (1, 6), (2, 10), (3, 20))
    rows: list[dict[str, object]] = []

    for user in users.itertuples(index=False):
        signup_day = user.signup_date
        previous_day = signup_day
        rows.append(
            {
                "event_id": f"E{len(rows) + 1:07d}",
                "user_id": user.user_id,
                "event_name": FUNNEL_STAGES[0],
                "event_timestamp": _event_timestamp(signup_day, rng),
            }
        )

        for stage_index, probability in enumerate(conditional_conversion, start=1):
            if rng.random() >= probability:
                break
            min_delay, max_delay = stage_delay_days[stage_index - 1]
            event_day = previous_day + timedelta(days=int(rng.integers(min_delay, max_delay + 1)))
            if event_day > AS_OF_DATE:
                break
            rows.append(
                {
                    "event_id": f"E{len(rows) + 1:07d}",
                    "user_id": user.user_id,
                    "event_name": FUNNEL_STAGES[stage_index],
                    "event_timestamp": _event_timestamp(event_day, rng),
                }
            )
            previous_day = event_day

    events = pd.DataFrame(rows)
    # Duplicate complete rows (including event_id) to simulate ingestion-quality issues.
    duplicate_count = round(len(events) * 0.05)
    duplicates = events.iloc[rng.choice(len(events), size=duplicate_count, replace=False)]
    events = pd.concat([events, duplicates], ignore_index=True)
    return events.sort_values(["user_id", "event_timestamp", "event_name"], kind="stable").reset_index(drop=True)


def generate_subscriptions(events: pd.DataFrame, users: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    paid_events = events.loc[events["event_name"] == "Upgraded_to_Paid"].drop_duplicates("user_id")
    user_sizes = users.set_index("user_id")["company_size"]
    rows: list[dict[str, object]] = []
    churn_count = round(len(paid_events) * 0.15)
    churned_users = set(rng.choice(paid_events["user_id"].to_numpy(), size=churn_count, replace=False)) if churn_count else set()

    for index, event in enumerate(paid_events.itertuples(index=False), start=1):
        start_day = event.event_timestamp.date()
        size = user_sizes[event.user_id]
        if size == "Enterprise":
            plan = rng.choice(("Pro", "Enterprise"), p=(0.25, 0.75))
        elif size == "Mid-Market":
            plan = rng.choice(("Starter", "Pro", "Enterprise"), p=(0.15, 0.75, 0.10))
        else:
            plan = rng.choice(("Starter", "Pro"), p=(0.70, 0.30))

        if plan == "Starter":
            mrr = round(float(rng.uniform(49, 199)), 2)
        elif plan == "Pro":
            mrr = round(float(rng.uniform(199, 999)), 2)
        else:
            mrr = round(float(rng.uniform(1_500, 8_000)), 2)

        churn_day = None
        if event.user_id in churned_users:
            earliest_churn = start_day + timedelta(days=14)
            if earliest_churn <= AS_OF_DATE:
                churn_day = earliest_churn + timedelta(
                    days=int(rng.integers(0, (AS_OF_DATE - earliest_churn).days + 1))
                )

        rows.append(
            {
                "sub_id": f"S{index:05d}",
                "user_id": event.user_id,
                "plan_tier": plan,
                "mrr_amount": mrr,
                "start_date": start_day,
                "churn_date": churn_day,
            }
        )

    return pd.DataFrame(
        rows,
        columns=["sub_id", "user_id", "plan_tier", "mrr_amount", "start_date", "churn_date"],
    )


def generate_monthly_channel_spend(rng: np.random.Generator) -> pd.DataFrame:
    """Create explicitly synthetic channel budgets at a month/channel grain."""
    months = pd.date_range("2025-01-01", AS_OF_DATE.replace(day=1), freq="MS")
    rows: list[dict[str, object]] = []
    for month_index, month in enumerate(months):
        seasonality = 1.0 + 0.08 * np.sin(2 * np.pi * (month.month - 1) / 12)
        growth = 1.0 + 0.01 * month_index
        for channel, (base_spend, campaign_name) in CHANNEL_SPEND_ASSUMPTIONS.items():
            if channel == "Unknown":
                spend = 0.0
            else:
                spend = max(0.0, float(rng.normal(base_spend * seasonality * growth, base_spend * 0.08)))
            channel_key = channel.upper().replace(" ", "_")
            rows.append(
                {
                    "spend_id": f"MCS-{month:%Y%m}-{channel_key}",
                    "spend_month": month.date(),
                    "acquisition_channel": channel,
                    "campaign_name": campaign_name,
                    "spend_amount": round(spend, 2),
                    "currency": "USD",
                    "spend_source": "Synthetic assumption",
                }
            )
    return pd.DataFrame(rows)


def main() -> None:
    args = parse_args()
    if args.users < 1:
        raise SystemExit("--users must be at least 1")

    rng = np.random.default_rng(args.seed)
    fake = Faker("en_US")
    fake.seed_instance(args.seed)

    users = generate_users(args.users, rng, fake)
    events = generate_events(users, rng)
    subscriptions = generate_subscriptions(events, users, rng)
    monthly_channel_spend = generate_monthly_channel_spend(rng)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    users.to_csv(args.output_dir / "users.csv", index=False, date_format="%Y-%m-%d")
    events.to_csv(args.output_dir / "funnel_events.csv", index=False, date_format="%Y-%m-%dT%H:%M:%S")
    subscriptions.to_csv(args.output_dir / "subscriptions.csv", index=False, date_format="%Y-%m-%d")
    monthly_channel_spend.to_csv(
        args.output_dir / "monthly_channel_spend.csv",
        index=False,
        date_format="%Y-%m-%d",
    )

    print(
        f"Generated {len(users):,} users, {len(events):,} funnel events, "
        f"{len(subscriptions):,} subscriptions, and {len(monthly_channel_spend):,} monthly channel-spend rows."
    )
    print(f"CSV files saved to: {args.output_dir.resolve()}")
    print(f"Funnel event rows include {round(len(events) * 0.05 / 1.05):,} intentional duplicate rows; as-of date: {AS_OF_DATE}.")


if __name__ == "__main__":
    main()
