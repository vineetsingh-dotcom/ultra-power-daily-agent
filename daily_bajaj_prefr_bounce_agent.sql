-- ============================================================
-- Daily EMI-Bounce Trend Report — BAJAJ / PREFR / PREFR_PL
-- Metric   : M1 (first EMI) T0 bounce (no payment-date tolerance)
-- Window   : trailing 10 completed EMI-due days (today excluded — not yet matured)
-- Methodology reference: bounce_context.md §2 (bounce windows) and §1
--   (Ring channel/cohort base pattern). Channel filter / FINAL_APPROVED
--   base pattern reused from bajaj_prefr.sql.
-- Safe to re-run: the trailing window is deleted and re-inserted into the
-- permanent log table each run, so re-running the same day just refreshes it.
-- ============================================================

SET window_start = DATEADD(day, -10, CURRENT_DATE);   -- 10 days ago
SET window_end   = DATEADD(day, -1, CURRENT_DATE);     -- yesterday (today's EMIs aren't due/matured yet)
SET txn_start_date = DATEADD(day, -60, CURRENT_DATE);  -- wide enough that M1 (due ~30d post-disbursal) can fall in the window

-- STEP 1: base cohort — approved loans on the 3 channels, wide enough to cover the window
-- ============================================================
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_bnc_base AS
SELECT
    t.transaction_reference_number AS fb_transaction_id,
    t.loan_reference_number,
    t.channel,
    t.loan_amount,
    t.instalment_amount,
    DATE(t.created_at) AS txn_date
FROM ring_source.bi.transactions t
WHERE t.status = 'FINAL_APPROVED'
  AND t.channel IN ('BAJAJ', 'PREFR', 'PREFR_PL')
  AND t.created_at >= $txn_start_date
  AND t.loan_reference_number IS NOT NULL
;

-- STEP 2: M1 repayment record per loan, EMI due date inside the trailing 10-day window
-- ============================================================
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_bnc_m1 AS
SELECT
    b.channel,
    b.loan_reference_number,
    DATE(r.scheduled_payment_date) AS emi_due_date,
    r.scheduled_payment_date,
    r.payment_date,
    CASE
        WHEN r.payment_date IS NOT NULL AND r.payment_date <= r.scheduled_payment_date THEN 1  -- paid on/before due date (T0)
        ELSE 0                                                                                  -- bounced: unpaid or paid late
    END AS paid_t0
FROM kissht_reports.temp_tables.tmp_bnc_base b
JOIN ring_source.bi.repayments r
    ON r.loan_reference_number = b.loan_reference_number
WHERE r.month = 1
  AND DATE(r.scheduled_payment_date) BETWEEN $window_start AND $window_end
QUALIFY ROW_NUMBER() OVER (PARTITION BY b.loan_reference_number ORDER BY r.scheduled_payment_date) = 1
;

-- STEP 3: log loan-level detail into a permanent rolling table (history kept; only the
-- trailing window is refreshed each run, so re-runs on the same day don't duplicate rows)
-- ============================================================
CREATE TABLE IF NOT EXISTS kissht_reports.temp_tables.daily_bajaj_prefr_bounce_log (
    run_date               DATE,
    emi_due_date           DATE,
    channel                VARCHAR,
    loan_reference_number  VARCHAR,
    paid_t0                INT
);

DELETE FROM kissht_reports.temp_tables.daily_bajaj_prefr_bounce_log
WHERE emi_due_date BETWEEN $window_start AND $window_end;

INSERT INTO kissht_reports.temp_tables.daily_bajaj_prefr_bounce_log
SELECT
    CURRENT_DATE AS run_date,
    emi_due_date,
    channel,
    loan_reference_number,
    paid_t0
FROM kissht_reports.temp_tables.tmp_bnc_m1
;

-- STEP 4: Slack-ready summary — one row per (emi_due_date, channel), last 10 days
-- ============================================================
SELECT
    emi_due_date,
    channel,
    COUNT(*)                                                                    AS total_emis_due,
    SUM(CASE WHEN paid_t0 = 1 THEN 1 ELSE 0 END)                                AS paid_on_time,
    SUM(CASE WHEN paid_t0 = 0 THEN 1 ELSE 0 END)                                AS bounced_count,
    ROUND(100.0 * SUM(CASE WHEN paid_t0 = 0 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 2) AS bounce_rate_pct
FROM kissht_reports.temp_tables.tmp_bnc_m1
GROUP BY emi_due_date, channel
ORDER BY emi_due_date DESC, channel
;
