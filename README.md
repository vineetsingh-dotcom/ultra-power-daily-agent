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
completed EMI-due days, plus today shown separately as "not yet due"**
(today's EMIs haven't matured yet, but showing the row lets you see today's
scheduled volume rather than a silent gap).

Pipeline:
1. Rebuilds a base cohort of `FINAL_APPROVED` loans on the 3 channels
   (`ring_source.bi.transactions`, last 60 days — wide enough that a loan's
   M1 due date, ~30 days post-disbursal, can fall inside the window).
2. Joins to `ring_source.bi.repayments` (`month = 1`) and flags each loan
   `paid_t0 = 1` (paid on/before its scheduled due date), `0` (bounced —
   unpaid or paid late), or `-1` (not yet due — `scheduled_payment_date >=
   CURRENT_DATE`), keeping only loans whose EMI due date falls in the last
   10 days or is today.
3. Logs loan-level detail into the permanent table
   `kissht_reports.temp_tables.daily_bajaj_prefr_bounce_log`, keyed by
   `emi_due_date` (safe to re-run — the window's rows are deleted and
   re-inserted, so re-running the same day doesn't duplicate).
4. Final summary `SELECT`: one row per `(emi_due_date, channel)` — columns
   `emi_due_date, channel, total_emis_due, paid_on_time, bounced_count,
   bounce_rate_pct, row_status` (`row_status` is `'not_yet_due'` for today,
   `'matured'` otherwise; `bounce_rate_pct` is `NULL` when `not_yet_due`) —
   ordered by `emi_due_date DESC, channel`.

**Slack format**: post one markdown table per channel — columns
`Scheduled Date | Paid | Bounced | Total Due | Bounce Rate` — most recent
matured day in **bold** with a ✅ on its bounce rate, and the trailing
"not yet due" row's Bounce Rate cell literal text `not yet due` instead of
a number. If a channel has no rows in the window (e.g. PREFR_PL sometimes
has none — see `bounce_context.md`), state that explicitly instead of
omitting the channel.

Run the whole file daily against Snowflake, same pattern as the ultra_power
agent above.
