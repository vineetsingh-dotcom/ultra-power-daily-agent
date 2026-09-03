# Ultra Power daily high-value-miss agent

`daily_ultra_power_high_value_miss_agent.sql` is the Sicreva repeat-offer
waterfall pipeline (`Scirevawf_21_26August.sql`, kept here unchanged for
reference) with two changes:

1. `start_date` / `end_date` / `fat_start_date` resolve to **yesterday**
   relative to run time, instead of a hardcoded historical range.
2. A **Step 6** appended at the end: among yesterday's applications where
   `aa_income > 40000 AND bureau_cibil_3_score > 760 AND user_gross_monthly_salary > 45000`,
   finds everyone `ultra_power_waterfall_scrupg` did NOT tag `'Approved'`,
   logs them (with the exact first-failing-rule reason) to
   `kissht_reports.temp_tables.daily_hv_ultra_power_miss_log` keyed by
   `run_date` (safe to re-run — same-day rows are replaced), and produces a
   summary result set of counts by reason.

Run the whole file daily against Snowflake. The final `SELECT` (the
"Slack-ready summary") is what a daily routine should read and post.

---

# Daily BAJAJ / PREFR / PREFR_PL bounce trend agent

`daily_bajaj_prefr_bounce_agent.sql` reports the **M1 (first EMI) T0 bounce
rate** (no payment-date tolerance — see `bounce_context.md` in the main
workspace for the bounce-window methodology) for the three channels
`BAJAJ`, `PREFR`, `PREFR_PL`, as a **daily trend over the trailing 10
completed EMI-due days** (today is excluded — its EMIs aren't due/matured
yet).

Pipeline:
1. Rebuilds a base cohort of `FINAL_APPROVED` loans on the 3 channels
   (`ring_source.bi.transactions`, last 60 days — wide enough that a loan's
   M1 due date, ~30 days post-disbursal, can fall inside the 10-day window).
2. Joins to `ring_source.bi.repayments` (`month = 1`) and flags each loan
   `paid_t0 = 1` (paid on/before its scheduled due date) or `0` (bounced —
   unpaid or paid late), keeping only loans whose EMI due date falls in the
   trailing 10-day window.
3. Logs loan-level detail into the permanent table
   `kissht_reports.temp_tables.daily_bajaj_prefr_bounce_log`, keyed by
   `emi_due_date` (safe to re-run — the trailing window's rows are deleted
   and re-inserted, so re-running the same day doesn't duplicate).
4. Final summary `SELECT`: one row per `(emi_due_date, channel)` — columns
   `emi_due_date, channel, total_emis_due, paid_on_time, bounced_count,
   bounce_rate_pct` — ordered by `emi_due_date DESC, channel`. This is what
   a daily routine should read and post (e.g. as a small trend table per
   channel across the 10 days).

Run the whole file daily against Snowflake, same pattern as the ultra_power
agent above.
