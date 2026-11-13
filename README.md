# Token Analytics: Is AI spend paying off?

An insight-led portfolio case study asking whether AI-assisted work creates enough value to justify its token cost.

**[Open the live insight page](https://philo-r76.github.io/Project-Portfolio/)** | [Open the dashboard source](reports/dashboard.html) | [Read the SQL](sql/analysis.sql)

The live page includes a recruiter-friendly executive readout and an embedded interactive dashboard. GitHub does not execute standalone HTML inside a repository view; the Pages workflow publishes it as a website.

> **Important:** The included data is entirely synthetic. It is designed to demonstrate an analysis workflow, not to make claims about real companies, real AI products, or actual ROI. Model prices, labor rates, outcomes, and time savings are simulated assumptions.

## Business question

Where does AI-assisted work appear to create enough labor capacity value to justify its API cost, and where should a company investigate before scaling?

The analysis compares estimated labor capacity value with token spend. It is an **ROI proxy**, not audited financial ROI: time saved only becomes cash savings when it is converted into measurable outcomes such as avoided hiring, reduced overtime, or additional delivered work.

## What's included

- `data/`: reproducible synthetic event, model-rate, and department-rate CSVs.
- `sql/schema.sql`: SQLite table definitions.
- `sql/analysis.sql`: monthly, department, workflow, model, and concentration analyses.
- `scripts/generate_data.ps1`: deterministic, dependency-free dataset generator.
- `scripts/validate_data.ps1`: checks identifiers, dates, numeric fields, and rate-card keys.
- `scripts/build_dashboard.ps1`: builds a standalone HTML dashboard from the CSVs.
- `reports/dashboard.html`: generated interactive dashboard.

The scenario is intentionally constructed to make the unit-economics tradeoffs visible. Its patterns are not empirical findings.

## Run it

Requirements: Windows PowerShell 5.1+ and SQLite 3.32+ (for loading the CSVs with the CLI).

```powershell
.\scripts\generate_data.ps1
.\scripts\validate_data.ps1
.\scripts\build_dashboard.ps1
Start-Process .\reports\dashboard.html
```

To run the SQL analysis from the project root using the SQLite CLI:

```text
sqlite3 token_analytics.db
```

Then enter:

```text
.read sql/schema.sql
.import --csv --skip 1 data/model_rates.csv model_rates
.import --csv --skip 1 data/department_rates.csv department_rates
.import --csv --skip 1 data/usage_events.csv usage_events
.read sql/analysis.sql
```

The scripts regenerate the same data with the fixed seed. The dashboard reads the generated CSVs; SQL analyses can be run independently in SQLite.

## Metric definitions

- **API cost** = input tokens × input price + output tokens × output price, with prices expressed per million tokens.
- **Net saved minutes** = estimated time saved − human review time.
- **Labor capacity value** = net saved minutes / 60 × assumed fully loaded hourly labor rate.
- **ROI proxy** = (labor capacity value − API cost) / API cost.
- **Successful-task rate** = successful tasks / all tasks.

An ROI proxy above zero means modeled labor capacity value exceeds modeled API spend under these assumptions. It does **not** prove cash savings, causality, or company-wide ROI.

## Data dictionary

### `usage_events.csv`

One row per simulated AI-assisted task: event ID, timestamp, department, workflow, user, model, input/output tokens, task outcome, estimated minutes saved, and human review minutes.

### `model_rates.csv`

Simulated input/output USD per million tokens by model. These are scenario assumptions, not vendor quotes.

### `department_rates.csv`

Simulated fully loaded labor USD per hour by department. These are scenario assumptions, not salary benchmarks.

## Portfolio narrative

1. **Frame the decision:** avoid treating token volume or adoption as business value.
2. **Measure unit economics:** compare estimated value after review effort against variable AI cost.
3. **Find where to investigate:** segment by team, workflow, model, month, and user concentration.
4. **Recommend a controlled pilot:** instrument task-level baselines and outcomes before scaling.

### Illustrative scenario readout

The generated scenario contains 10,230 tasks, with $5,863.97 in modeled API spend and $39,024.01 in modeled labor capacity value after review effort (565.5% aggregate ROI proxy). These figures describe only the simulation.

The decision signal is not "scale AI everywhere." `Nova-Large` has a much higher average cost per task than `Open-Compact` ($1.75 vs. $0.07), while the synthetic success rates are close (79.8% vs. 81.7%). Engineering is the highest-spend department ($1,772.61) and has the lowest department ROI proxy in this scenario (414.1%). This makes model routing and a closer Engineering workflow review sensible **pilot hypotheses**, not proven recommendations: task mix differs by model and team, and the success labels are simulated.

**Business recommendation:** pilot model routing on matched, high-volume workflows; protect quality and rework thresholds; and verify whether reclaimed capacity translates into measurable output or avoided cost before scaling.

For a real pilot, compare matched tasks with and without AI, verify quality and rework, and measure whether time saved is redeployed or converted to cash outcomes. Keep token spend, task success, review effort, and realized business value visible together.

### Decision guardrails

- Compare against a baseline or control group; the synthetic data cannot establish causality.
- Track quality, rework, latency, adoption, and privacy/security constraints alongside cost.
- Validate whether saved time was actually redeployed or converted into cash outcomes.
- Replace every simulated assumption with finance-approved rates and measured outcomes before using this for a real investment decision.

## Extending with real data

For a defensible company analysis, join privacy-reviewed provider usage exports to task/workflow metadata and outcome measurement. Required fields include timestamp, provider/model, input and output tokens, billed cost, team/workflow, task outcome, baseline time, review/rework time, and an agreed method to value reclaimed capacity. Keep user identifiers pseudonymized and follow company data-retention and access policies.

## Publishing

The repository includes a GitHub Actions workflow for GitHub Pages. If the first deployment reports that Pages is not enabled, open **Settings → Pages**, choose **GitHub Actions** as the build and deployment source, and rerun the `Publish portfolio insight page` workflow. The site URL is `https://philo-r76.github.io/Project-Portfolio/`.
