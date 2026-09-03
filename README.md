# Ultra Power daily high-value-miss agent

## What this answers

Every day, among **repeat-loan applications** where the customer looks clearly
credit-worthy on paper —

```
aa_income > 40000  OR  bureau_cibil_3_score > 760  OR  user_gross_monthly_salary > 45000
```

— how many were **not** tagged `'Approved'` by `ultra_power_waterfall_scrupg`,
and exactly why. It exists to catch two kinds of mistakes: the policy
behaving unexpectedly on obviously-good customers, or an upstream feed/join
silently breaking (see "Bugs this already caught" below — it found a real one
on day one).

## Files

| File | Purpose |
|---|---|
| `Scirevawf_21_26August.sql` | The original Sicreva repeat-offer waterfall pipeline (Ring platform), kept unmodified for reference. |
| `daily_ultra_power_high_value_miss_agent.sql` | The same pipeline, parameterized to always run for **yesterday**, with two extra steps appended (see below). This is the file that actually runs daily. |
| `run_daily_agent.py` | **Not committed to this repo** (it's gitignored — see Secrets below). Runs the SQL file against Snowflake and posts the results to Slack. |
| `run_report.bat` | Double-click to trigger `run_daily_agent.py` manually. |
| Desktop shortcut "Run Ultra Power Report" | Same as the batch file, one click from the Desktop. |

## What changed vs. the original pipeline

1. **`start_date` / `end_date` / `fat_start_date`** resolve to yesterday
   relative to run time (`DATEADD(day, -1, CURRENT_DATE())`), instead of a
   hardcoded historical range.
2. **Step 6** (appended at the end): finds every yesterday application
   matching the high-value condition above where `ultra_power_waterfall_scrupg`
   did not say `'Approved'`, and logs each one — with the exact first-failing
   reason — to `kissht_reports.temp_tables.daily_hv_ultra_power_miss_log`,
   keyed by `run_date` (safe to re-run: same-day rows are replaced via
   `DELETE` + `INSERT`, not accumulated). Produces a summary (customers
   missed per reason, with median cibil/salary/aa_income) as its last
   `SELECT` — this is what gets posted to Slack.
3. **Step 7**: `ultra_power_waterfall_scrupg` only names the *first* of the
   28 benchmark checks (dt-20 `ultra_power_scr_upg`) a customer failed. Step
   7 adds two columns that instead count and name **every** failing check
   (`ultra_power_scrupg_fail_count`, `ultra_power_scrupg_fail_reasons`), and
   a view — `kissht_reports.temp_tables.daily_hv_ultra_power_failcount_view`
   — grouping customers by how many reasons they failed on (1, 2, 3, 4+) and
   by the exact combination of reasons, with median customer stats per
   combination. Answers "how many customers failed for exactly N reasons,"
   not just "what was the first reason."

## Running it

**Manual (today):** double-click `run_report.bat` or the "Run Ultra Power
Report" desktop shortcut. A console window shows progress; a browser tab may
briefly open for Snowflake SSO (usually auto-completes from a cached
session — click through it if it doesn't). Takes a few minutes (it rebuilds
the full pipeline over real Snowflake tables). Posts two messages to
`#ultra_power_src_upg`: the main miss-reason summary, then the fail-count
breakdown.

**Fully automatic:** not yet wired up. Two blockers, either fixable:
- The Claude cloud-routine path (`https://claude.ai/code/routines`) is built
  but blocked — the Kissht Snowflake MCP connector rejects this account
  ("Ask prashant.kumar@kissht.com to be added to the MCP permission list").
- A local Windows Task Scheduler job is the fallback, but the script
  authenticates via `authenticator='externalbrowser'` (SSO through Chrome),
  which needs the machine on, you logged in, and a valid cached SSO session —
  not fully unattended-safe. Switching to Snowflake key-pair auth would make
  it so; ask if you want that set up.

## Secrets

`run_daily_agent.py` has the Slack incoming-webhook URL for
`#ultra_power_src_upg` hardcoded in it. **This repo is public** (needed for
the Claude cloud-routine integration), so that file is deliberately excluded
via `.gitignore` and must never be committed — anyone with that URL can post
into the channel. If you need to recreate it, generate a new one at
[api.slack.com/apps](https://api.slack.com/apps) → Incoming Webhooks.

## Bugs this already caught

- **`aa_income` was always `NULL`** — the pipeline read it from source
  record-type `finbox_variables`, which never carries that field (0%
  populated). The real value lives under `offer_computation_variables`
  (100% populated) — fixed in Step 2b. Before this fix, the high-value
  filter was silently blind to the `aa_income > 40000` condition entirely.

## Possible next steps

- Feed `daily_hv_ultra_power_miss_log` / `daily_hv_ultra_power_failcount_view`
  into a BI tool (Tableau/Power BI/Sigma) if one is already connected to this
  Snowflake account, for trend charts across days instead of one-day-at-a-time
  Slack messages.
- Add an email digest alongside Slack.
- Switch to Snowflake key-pair auth for true unattended scheduling.

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

**Slack format**: post one table per channel — columns `DATE | PAID |
BOUNCED | TOTAL | RATE` — most recent matured day marked `<-- latest`, and
the trailing "not yet due" row's rate cell reading literally `not yet due`
instead of a number. If a channel has no rows in the window (e.g. PREFR_PL
sometimes has none — see `bounce_context.md`), state that explicitly
instead of omitting the channel.

## Files (bounce agent)

| File | Purpose |
|---|---|
| `daily_bajaj_prefr_bounce_agent.sql` | The pipeline above. This is the file that actually runs. |
| `run_bounce_daily_agent.py` | **Not committed to this repo** (gitignored — see Secrets). Runs the SQL against Snowflake and posts the per-channel trend table to Slack. |
| `run_bounce_report.bat` | Double-click to trigger `run_bounce_daily_agent.py` manually. |
| Desktop shortcut "Run Bounce Report" | Same as the batch file, one click from the Desktop. |

## Running it (bounce agent)

**Manual (today):** double-click `run_bounce_report.bat` or the "Run Bounce
Report" desktop shortcut. A console window shows progress; a browser tab
may briefly open for Snowflake SSO (usually auto-completes from a cached
session — click through it if it doesn't). Posts one message to
`#bajaj_prefr_bounce` with a table per channel.

**Fully automatic:** not wired up, same two blockers as the ultra_power
agent above (Kissht Snowflake MCP connector access, and externalbrowser SSO
not being unattended-safe for Task Scheduler) — same fix (Snowflake
key-pair auth) would unblock both agents at once.

**Secrets:** `run_bounce_daily_agent.py` has the Slack incoming-webhook URL
for `#bajaj_prefr_bounce` hardcoded in it, same reasoning as
`run_daily_agent.py` above (this repo is public) — never commit it. If you
need to recreate it: [api.slack.com/apps](https://api.slack.com/apps) →
Incoming Webhooks → Add New Webhook to Workspace → pick `#bajaj_prefr_bounce`.

Run the whole SQL file daily against Snowflake, same pattern as the
ultra_power agent above.
