# Ultra Power daily high-value-miss agent

`daily_ultra_power_high_value_miss_agent.sql` is the Sicreva repeat-offer
waterfall pipeline (`Scirevawf_21_26August.sql`, kept here unchanged for
reference) with two changes:

1. `start_date` / `end_date` / `fat_start_date` resolve to **yesterday**
   relative to run time, instead of a hardcoded historical range.
2. A **Step 6** appended at the end: among yesterday's applications where
   `aa_income > 40000 OR bureau_cibil_3_score > 760 OR user_gross_monthly_salary > 45000`,
   finds everyone `ultra_power_waterfall_scrupg` did NOT tag `'Approved'`,
   logs them (with the exact first-failing-rule reason) to
   `kissht_reports.temp_tables.daily_hv_ultra_power_miss_log` keyed by
   `run_date` (safe to re-run — same-day rows are replaced), and produces a
   summary result set of counts by reason.

Run the whole file daily against Snowflake. The final `SELECT` (the
"Slack-ready summary") is what a daily routine should read and post.
