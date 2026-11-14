"""Local Streamlit dashboard for the SaaS funnel DuckDB Gold model."""

from __future__ import annotations

from pathlib import Path

import duckdb
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

PROJECT_ROOT = Path(__file__).resolve().parent
DATABASE_PATH = PROJECT_ROOT / "data" / "warehouse" / "saas_funnel.duckdb"
STAGE_LABELS = {
    1: "Account Created",
    2: "Workspace Setup",
    3: "Team Invited",
    4: "First Integration",
    5: "Upgraded to Paid",
}
PALETTE = ["#20A4F3", "#0C7C9C", "#00A896", "#F4A261", "#E76F51"]

st.set_page_config(
    page_title="SaaS Funnel Analytics",
    page_icon="📈",
    layout="wide",
    initial_sidebar_state="expanded",
)
st.markdown(
    """
    <style>
      .block-container {padding-top: 1.8rem; padding-bottom: 2rem;}
      [data-testid="stMetric"] {background: #111827; border: 1px solid #263244;
        padding: 1rem 1.2rem; border-radius: 0.8rem;}
      [data-testid="stMetricLabel"] {color: #9CA3AF;}
      h1 {letter-spacing: -0.035em;}
      .subtitle {color: #94A3B8; margin-top: -0.7rem; margin-bottom: 1.3rem;}
    </style>
    """,
    unsafe_allow_html=True,
)


@st.cache_data(ttl=60)
def load_gold_tables(database_path: str) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Load the small Gold dimensions and fact for interactive local filtering."""
    with duckdb.connect(database_path, read_only=True) as connection:
        users = connection.execute("SELECT * FROM dim_users").df()
        milestones = connection.execute("SELECT * FROM fact_funnel_milestones").df()
        economics = connection.execute("SELECT * FROM fact_channel_economics").df()
    users["signup_date"] = pd.to_datetime(users["signup_date"])
    milestones["stage_date"] = pd.to_datetime(milestones["stage_date"])
    milestones["mrr_value"] = pd.to_numeric(milestones["mrr_value"], errors="coerce").fillna(0.0)
    economics["signup_month"] = pd.to_datetime(economics["signup_month"])
    for column in (
        "marketing_spend",
        "customer_acquisition_cost",
        "average_paid_mrr",
        "gross_margin_pct",
        "estimated_payback_months",
        "active_arr",
        "mature_paid_conversion_pct",
        "paid_churn_pct",
    ):
        economics[column] = pd.to_numeric(economics[column], errors="coerce")
    return users, milestones, economics


def format_currency(value: float) -> str:
    return f"${value:,.0f}"


def render_funnel_view(users: pd.DataFrame, milestones: pd.DataFrame) -> None:
    stage_counts = (
        milestones.groupby("stage_order")["user_id"]
        .nunique()
        .reindex(range(1, 6), fill_value=0)
    )
    signup_count = int(users["user_id"].nunique())
    paid_count = int(stage_counts.loc[5])
    paid_milestones = milestones.loc[milestones["stage_order"] == 5]
    paid_with_users = paid_milestones.merge(users[["user_id", "is_churned"]], on="user_id", how="inner")
    active_arr = float(paid_with_users.loc[~paid_with_users["is_churned"], "mrr_value"].sum() * 12)
    avg_days_to_paid = paid_milestones["days_from_signup"].mean()
    conversion_rate = paid_count / signup_count if signup_count else 0.0

    metric_columns = st.columns(4)
    metric_columns[0].metric("Signups", f"{signup_count:,}")
    metric_columns[1].metric("Paid conversion", f"{conversion_rate:.1%}")
    metric_columns[2].metric("Avg. days to paid", f"{avg_days_to_paid:.1f}" if pd.notna(avg_days_to_paid) else "—")
    metric_columns[3].metric("Active ARR", format_currency(active_arr))

    chart_columns = st.columns((1.1, 0.9))
    with chart_columns[0]:
        st.subheader("Funnel progression")
        funnel = go.Figure(
            go.Funnel(
                y=[STAGE_LABELS[index] for index in range(1, 6)],
                x=[int(stage_counts.loc[index]) for index in range(1, 6)],
                textinfo="value+percent initial",
                marker={"color": PALETTE},
                connector={"line": {"color": "#334155", "width": 1}},
            )
        )
        funnel.update_layout(height=390, margin={"l": 5, "r": 5, "t": 10, "b": 5}, showlegend=False)
        st.plotly_chart(funnel, width="stretch")

    with chart_columns[1]:
        st.subheader("Step-to-step conversion")
        step_rates = [100.0]
        for stage in range(2, 6):
            previous_count = int(stage_counts.loc[stage - 1])
            current_count = int(stage_counts.loc[stage])
            step_rates.append(current_count / previous_count * 100 if previous_count else 0.0)
        conversion_chart = go.Figure(
            go.Bar(
                x=[STAGE_LABELS[index] for index in range(1, 6)],
                y=step_rates,
                marker_color=PALETTE,
                text=[f"{rate:.1f}%" for rate in step_rates],
                textposition="outside",
                cliponaxis=False,
            )
        )
        conversion_chart.update_layout(
            height=390,
            yaxis={"title": "Conversion from prior stage", "range": [0, 115], "ticksuffix": "%"},
            margin={"l": 5, "r": 5, "t": 20, "b": 5},
            showlegend=False,
        )
        st.plotly_chart(conversion_chart, width="stretch")

    st.subheader("Stage velocity by company size")
    velocity = milestones.loc[milestones["stage_order"] > 1].merge(
        users[["user_id", "company_size"]], on="user_id", how="inner"
    )
    if velocity.empty:
        st.info("No post-signup milestones match the current filters.")
    else:
        velocity = (
            velocity.groupby(["stage_order", "company_size"], as_index=False)["days_from_previous_stage"]
            .mean()
            .rename(columns={"days_from_previous_stage": "Average days"})
        )
        velocity["stage"] = velocity["stage_order"].map(STAGE_LABELS)
        chart = go.Figure()
        for size in ("SMB", "Mid-Market", "Enterprise", "Unknown"):
            segment = velocity.loc[velocity["company_size"] == size]
            if not segment.empty:
                chart.add_trace(
                    go.Bar(name=size, x=segment["stage"], y=segment["Average days"])
                )
        chart.update_layout(
            barmode="group",
            height=360,
            yaxis_title="Average days from previous stage",
            margin={"l": 5, "r": 5, "t": 10, "b": 5},
            legend_title_text="Company size",
        )
        st.plotly_chart(chart, width="stretch")


def render_cohort_view(users: pd.DataFrame, milestones: pd.DataFrame) -> None:
    st.subheader("Signup cohort conversion")
    cohort_users = users[["user_id", "signup_date"]].copy()
    cohort_users["cohort_month"] = cohort_users["signup_date"].dt.to_period("M").dt.to_timestamp()
    cohort_sizes = cohort_users.groupby("cohort_month")["user_id"].nunique()
    cohort_milestones = milestones.merge(cohort_users[["user_id", "cohort_month"]], on="user_id", how="inner")
    cohort_counts = cohort_milestones.groupby(["cohort_month", "stage_order"])["user_id"].nunique()
    cohort_rates = cohort_counts.div(cohort_sizes, level="cohort_month").mul(100).rename("conversion_pct").reset_index()
    cohort_pivot = cohort_rates.pivot(index="cohort_month", columns="stage_order", values="conversion_pct")
    cohort_pivot = cohort_pivot.reindex(columns=range(1, 6)).sort_index(ascending=False)
    cohort_pivot.columns = [STAGE_LABELS[index] for index in cohort_pivot.columns]

    if cohort_pivot.empty:
        st.info("No signup cohorts match the current filters.")
    else:
        text_values = cohort_pivot.apply(lambda column: column.map(lambda value: "" if pd.isna(value) else f"{value:.0f}%"))
        heatmap = go.Figure(
            go.Heatmap(
                z=cohort_pivot.to_numpy(),
                x=cohort_pivot.columns.tolist(),
                y=[value.strftime("%b %Y") for value in cohort_pivot.index],
                text=text_values.to_numpy(),
                texttemplate="%{text}",
                colorscale="Tealgrn",
                zmin=0,
                zmax=100,
                colorbar={"title": "Conversion"},
                hovertemplate="Cohort %{y}<br>%{x}: %{z:.1f}%<extra></extra>",
            )
        )
        heatmap.update_layout(height=max(420, 30 * len(cohort_pivot)), margin={"l": 5, "r": 5, "t": 10, "b": 5})
        st.plotly_chart(heatmap, width="stretch")
        st.caption("Recent signup cohorts have had less time to reach later stages; compare cohorts at similar maturity.")

    st.subheader("Channel performance: conversion, ARR, and churn")
    st.caption("Acquisition cost is not included in this dataset, so CAC, payback, and marketing ROI are not calculated.")
    channel_users = users.groupby("acquisition_channel").agg(
        signups=("user_id", "nunique"),
        churned_users=("is_churned", "sum"),
    )
    paid = milestones.loc[milestones["stage_order"] == 5].merge(
        users[["user_id", "acquisition_channel", "is_churned"]], on="user_id", how="inner"
    )
    paid_summary = paid.groupby("acquisition_channel").agg(
        paid_users=("user_id", "nunique"),
        churned_paid_users=("is_churned", "sum"),
        active_mrr=("mrr_value", lambda values: float(values[~paid.loc[values.index, "is_churned"]].sum())),
    )
    channel_summary = channel_users.join(paid_summary, how="left").fillna(0)
    channel_summary["paid_conversion_pct"] = channel_summary["paid_users"].div(channel_summary["signups"]).mul(100)
    channel_summary["churn_pct"] = channel_summary["churned_paid_users"].div(
        channel_summary["paid_users"].replace(0, pd.NA)
    ).fillna(0).mul(100)
    channel_summary["active_arr"] = channel_summary["active_mrr"] * 12
    channel_summary = channel_summary.reset_index()

    table_column, chart_column = st.columns((1, 1))
    with table_column:
        st.dataframe(
            channel_summary[
                ["acquisition_channel", "signups", "paid_users", "paid_conversion_pct", "churn_pct", "active_arr"]
            ].rename(
                columns={
                    "acquisition_channel": "Channel",
                    "signups": "Signups",
                    "paid_users": "Paid users",
                    "paid_conversion_pct": "Paid conversion %",
                    "churn_pct": "Paid churn %",
                    "active_arr": "Active ARR",
                }
            ).style.format(
                {"Paid conversion %": "{:.1f}%", "Paid churn %": "{:.1f}%", "Active ARR": "${:,.0f}"}
            ),
            hide_index=True,
            width="stretch",
        )
    with chart_column:
        channel_chart = go.Figure(
            go.Bar(
                x=channel_summary["acquisition_channel"],
                y=channel_summary["active_arr"],
                marker_color="#20A4F3",
                text=[format_currency(value) for value in channel_summary["active_arr"]],
                textposition="outside",
            )
        )
        channel_chart.update_layout(
            height=330,
            yaxis_title="Active ARR",
            margin={"l": 5, "r": 5, "t": 15, "b": 5},
        )
        st.plotly_chart(channel_chart, width="stretch")


def render_channel_economics_view(
    economics: pd.DataFrame,
    selected_channels: list[str],
    start_date,
    end_date,
) -> None:
    st.subheader("Mature-cohort acquisition economics")
    st.caption(
        "CAC is monthly channel spend divided by paid users from that signup-month cohort. "
        "Payback estimates use the configured gross-margin assumption."
    )
    st.warning(
        "Spend and gross margin are synthetic assumptions, not actual invoices or company financials. "
        "Unknown-channel paid users are excluded from attributed CAC."
    )

    start_month = pd.Timestamp(start_date).to_period("M").to_timestamp()
    end_month = pd.Timestamp(end_date).to_period("M").to_timestamp()
    filtered = economics.loc[
        economics["acquisition_channel"].isin(selected_channels)
        & economics["signup_month"].between(start_month, end_month)
    ].copy()
    if filtered.empty:
        st.info("No fully mature signup-month cohorts are available for this filter range.")
        return

    costed = filtered.loc[filtered["marketing_spend"] > 0].copy()
    total_spend = float(costed["marketing_spend"].sum())
    total_paid = int(costed["paid_users"].sum())
    total_signups = int(filtered["mature_signups"].sum())
    total_cohort_paid = int(filtered["paid_users"].sum())
    blended_cac = total_spend / total_paid if total_paid else None
    paid_mrr_total = float((costed["average_paid_mrr"].fillna(0) * costed["paid_users"]).sum())
    blended_paid_mrr = paid_mrr_total / total_paid if total_paid else None
    gross_margin_values = costed.loc[costed["gross_margin_pct"].notna(), "gross_margin_pct"]
    gross_margin_pct = float(gross_margin_values.iloc[0]) if not gross_margin_values.empty else None
    blended_payback = (
        blended_cac / (blended_paid_mrr * gross_margin_pct)
        if blended_cac is not None and blended_paid_mrr and gross_margin_pct
        else None
    )
    conversion_rate = total_cohort_paid / total_signups if total_signups else 0.0
    max_mature_month = filtered["signup_month"].max().strftime("%b %Y")

    metrics = st.columns(4)
    metrics[0].metric("Attributed spend", format_currency(total_spend))
    metrics[1].metric("Attributed paid users", f"{total_paid:,}")
    metrics[2].metric("Blended CAC", format_currency(blended_cac) if blended_cac is not None else "—")
    metrics[3].metric("Estimated payback", f"{blended_payback:.1f} mo" if blended_payback is not None else "—")
    st.caption(
        f"Mature cohort signup-to-paid conversion: {conversion_rate:.1%} · "
        f"gross margin assumption: {gross_margin_pct:.0%}" if gross_margin_pct is not None
        else f"Mature cohort signup-to-paid conversion: {conversion_rate:.1%}"
    )
    st.caption(f"Latest fully mature signup month included: {max_mature_month}.")

    channel_summary = (
        filtered.groupby("acquisition_channel", as_index=False)
        .agg(
            mature_signups=("mature_signups", "sum"),
            paid_users=("paid_users", "sum"),
            marketing_spend=("marketing_spend", "sum"),
            active_arr=("active_arr", "sum"),
        )
    )
    paid_mrr = costed.assign(paid_mrr_total=costed["average_paid_mrr"].fillna(0) * costed["paid_users"])
    paid_mrr_by_channel = paid_mrr.groupby("acquisition_channel")["paid_mrr_total"].sum()
    channel_summary["paid_mrr_total"] = channel_summary["acquisition_channel"].map(paid_mrr_by_channel).fillna(0)
    channel_summary["paid_conversion_pct"] = (
        100 * channel_summary["paid_users"] / channel_summary["mature_signups"].replace(0, pd.NA)
    )
    channel_summary["cac"] = (
        channel_summary["marketing_spend"] / channel_summary["paid_users"].replace(0, pd.NA)
    )
    channel_summary.loc[channel_summary["marketing_spend"] <= 0, "cac"] = pd.NA
    channel_summary["estimated_payback_months"] = channel_summary["cac"] / (
        channel_summary["paid_mrr_total"]
        / channel_summary["paid_users"].replace(0, pd.NA)
        * (gross_margin_pct or 0)
    )

    chart_columns = st.columns(2)
    with chart_columns[0]:
        st.subheader("Blended CAC by channel")
        cac_data = channel_summary.dropna(subset=["cac"]).sort_values("cac")
        cac_chart = go.Figure(
            go.Bar(
                x=cac_data["acquisition_channel"],
                y=cac_data["cac"],
                marker_color="#20A4F3",
                text=[format_currency(value) for value in cac_data["cac"]],
                textposition="outside",
            )
        )
        cac_chart.update_layout(
            height=350,
            yaxis_title="Spend per mature-cohort paid user",
            margin={"l": 5, "r": 5, "t": 15, "b": 5},
        )
        st.plotly_chart(cac_chart, width="stretch")

    with chart_columns[1]:
        st.subheader("CAC trend by signup month")
        trend = (
            filtered.loc[filtered["marketing_spend"] > 0]
            .groupby(["signup_month", "acquisition_channel"], as_index=False)
            .agg(marketing_spend=("marketing_spend", "sum"), paid_users=("paid_users", "sum"))
        )
        trend = trend.loc[trend["paid_users"] > 0]
        trend["cac"] = trend["marketing_spend"] / trend["paid_users"]
        trend_chart = go.Figure()
        for channel in selected_channels:
            channel_trend = trend.loc[trend["acquisition_channel"] == channel]
            if not channel_trend.empty:
                trend_chart.add_trace(
                    go.Scatter(
                        name=channel,
                        x=channel_trend["signup_month"],
                        y=channel_trend["cac"],
                        mode="lines+markers",
                    )
                )
        trend_chart.update_layout(
            height=350,
            yaxis_title="CAC",
            margin={"l": 5, "r": 5, "t": 15, "b": 5},
            legend_title_text="Channel",
        )
        st.plotly_chart(trend_chart, width="stretch")

    st.subheader("Mature cohort economics by channel")
    display = channel_summary[
        [
            "acquisition_channel",
            "mature_signups",
            "paid_users",
            "paid_conversion_pct",
            "marketing_spend",
            "cac",
            "estimated_payback_months",
            "active_arr",
        ]
    ].rename(
        columns={
            "acquisition_channel": "Channel",
            "mature_signups": "Mature signups",
            "paid_users": "Paid users",
            "paid_conversion_pct": "Paid conversion %",
            "marketing_spend": "Spend",
            "cac": "CAC",
            "estimated_payback_months": "Est. payback (mo)",
            "active_arr": "Active ARR",
        }
    )
    st.dataframe(
        display.style.format(
            {
                "Paid conversion %": "{:.1f}%",
                "Spend": "${:,.0f}",
                "CAC": "${:,.0f}",
                "Est. payback (mo)": "{:.1f}",
                "Active ARR": "${:,.0f}",
            },
            na_rep="—",
        ),
        hide_index=True,
        width="stretch",
    )


def main() -> None:
    st.title("SaaS Customer Funnel & Lifecycle")
    st.markdown('<p class="subtitle">Local analytics powered by DuckDB · synthetic data · no cloud account required</p>', unsafe_allow_html=True)

    if not DATABASE_PATH.is_file():
        st.error("The local DuckDB database has not been built yet. Run `python scripts/run_local_pipeline.py` first.")
        st.stop()

    try:
        users, milestones, economics = load_gold_tables(str(DATABASE_PATH))
    except duckdb.Error as error:
        st.error(f"Could not read the Gold tables: {error}. Run the local pipeline again.")
        st.stop()

    with st.sidebar:
        st.header("Filters")
        channels = sorted(users["acquisition_channel"].dropna().unique().tolist())
        selected_channels = st.multiselect("Acquisition channel", channels, default=channels)
        company_sizes = sorted(users["company_size"].dropna().unique().tolist())
        selected_sizes = st.multiselect("Company size", company_sizes, default=company_sizes)
        min_signup = users["signup_date"].min().date()
        max_signup = users["signup_date"].max().date()
        signup_range = st.date_input("Signup date range", value=(min_signup, max_signup), min_value=min_signup, max_value=max_signup)

    if isinstance(signup_range, tuple) and len(signup_range) == 2:
        start_date, end_date = signup_range
    elif isinstance(signup_range, tuple) and len(signup_range) == 1:
        start_date = end_date = signup_range[0]
    else:
        start_date = end_date = signup_range

    filtered_users = users.loc[
        users["acquisition_channel"].isin(selected_channels)
        & users["company_size"].isin(selected_sizes)
        & users["signup_date"].dt.date.between(start_date, end_date)
    ].copy()
    filtered_milestones = milestones.loc[milestones["user_id"].isin(filtered_users["user_id"])].copy()

    executive_tab, cohort_tab, economics_tab = st.tabs(
        ["Executive funnel", "Cohorts & channel performance", "Channel economics"]
    )
    with executive_tab:
        render_funnel_view(filtered_users, filtered_milestones)
    with cohort_tab:
        render_cohort_view(filtered_users, filtered_milestones)
    with economics_tab:
        render_channel_economics_view(economics, selected_channels, start_date, end_date)

    st.sidebar.caption(f"Showing {filtered_users['user_id'].nunique():,} of {users['user_id'].nunique():,} signups")
    st.sidebar.caption("ARR is annualized MRR for paid users not churned as of the pipeline date.")


if __name__ == "__main__":
    main()
