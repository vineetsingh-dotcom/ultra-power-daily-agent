/* ===========================================================================
   SICREVA REPEAT OFFER WATERFALL  --  Ring platform only
   ===========================================================================

  

   WHAT THIS ANSWERS
     For every repeat loan application on Ring, this script answers:
       1. Did the customer get an offer, and if not, where did they drop out?
       2. Which of the 65 Sicreva policy rules could they have qualified for?
       3. Exactly which policy variable was the FIRST one to fail?

   THE ONE IDEA YOU NEED
     Sicreva's offer policy is a DECISION TABLE (dt_table.csv). Picture a
     spreadsheet: 65 rows (rules) x 53 columns (customer variables), plus one
     "Output" column holding a segment name like 'si_lt_repeat_wl_24m'.
       * A rule fires only when EVERY non-blank cell in its row is satisfied.
       * A BLANK cell means "don't care".
       * The engine reads rows TOP TO BOTTOM and takes the FIRST rule that fires.
     This script reproduces that table in SQL: one block of AND-conditions per row.

   HOW THE DATA FLOWS   (each step builds a table the next step reads)

     STEP 1   tmp_loanref_mapping_tenure_analysis_WF  every repeat Ring txn
                |
     STEP 2   tmp_c2_transactions                     one row per txn (dedup)
                |
     STEP 2b  tmp_c2_finbox_pivot                     finbox policy variables
     STEP 2c  tmp_loanref..._c5                       v43 model score (backup)
     STEP 2d  tmp_c2_eqfx                             Equifax bureau snapshot
     STEP 3   tmp_c2_fat                              FAT vars (age, DPD, bureau)
                |
     STEP 4   tmp_c2_flags      <-- joins all of the above and turns each raw
                |                   variable into a 1/0 PASS flag
     STEP 5   wf_21_07_output   <-- the reportable output columns

   NAMING CONVENTIONS   (this is most of the readability battle)

     rv_<name>      "raw value" - the variable itself, untouched. Use these when
                    you want to see the actual number.
     seg_<name>     a 1/0 flag for ONE Sicreva decision-table condition.
                    1 = passed, 0 = failed.
     iop_ / imp_ /  1/0 flags for the OLDER, WIDER *app-level* decision table.
     r1_risk_       These are NOT Sicreva segment conditions - don't mix them up.

     Thresholds inside a flag name:
       _0 / _1 / _5  = "<= that number"      ge = ">="      gt = ">"      eq = "=="
       seg_loan_max_dpd_4     ->  loan_last_loan_max_dpd        <= 4
       seg_months_90dpd_ge12  ->  months_since_last_90_dpd      >= 12
       seg_loc_tenure_ge18    ->  v43_location_based_tenure     >= 18

   OUTPUT COLUMNS IN STEP 5   (what you actually read in the result)

     rejection_stage            coarse funnel stage the txn died at
     app_first_rejection_flag   'Approved' if ANY of the 59 rules fires; else the
                                first failing APP-LEVEL check
                                (59 = the 68 rows of dt_table (1).csv minus the three *_aast_upg
                                 rows and the six status=='Inactive' rows, removed 2026-08-31)
     app_first_rejection_value  same, but as 'variable=value' so you can see the
                                number that caused it. NULLs print as <null>
     equifax_check              which Equifax bucket rejected them (Check1/2/3)
     sub_reason                 stage-prefixed drill-down of the above
     ultra_power_waterfall  \   PER-FAMILY VERDICT. 'Approved' = the customer satisfied
     power_waterfall         >  ANY ONE rule of that family (rules tested in DT order).
     best_waterfall         /   Otherwise the family's LAST DT rule is the segment of
                                record and its checks are walked in DT COLUMN order;
                                the first that fails is the reported reason.
                                Fail drivers: ultra_power -> dt 22 ultra_power_pbt_upg
                                              power       -> dt 33 power_pbt_upg
                                              best        -> dt 57 best_scr_upg

   GOTCHAS   (learned the hard way - please don't "simplify" these away)

     * -1 in bureau_cibil_3_months_since_last_{0,90}_dpd means "NEVER had DPD",
       i.e. a GOOD thing. Step 3 remaps it to 999 so "> 3" / ">= 12" pass naturally.
     * v43_model_band = 100 means UNSCORED, not "worst decile". Never bucket it
       together with band 10.
     * Everything in fat_flatten_data is stored as TEXT, including scores.
     * repeat_offer_variable.final_emi comes back as -1 when no offer was computed.
     * finbox_variables.status is a hardcoded "Active" in the policy workbook, so
       the 6 rules whose status cell said "Inactive" could never fire in production
       (dt 1, 3, 4, 5, 55, 56). They were REMOVED on 2026-08-31 - pure dead-code
       elimination, no behavioural change. If status ever stops being hardcoded,
       restore them from dt_table (1).csv before trusting this file.
     * Five segment names appear on TWO rules each (dt 20/21, 31/32, 41/57, 61/62,
       64/65). Because the engine is first-match-wins, the UPPER row absorbs
       everything and the lower row approves nobody. Never add up failure counts
       across such a pair.
     * risk_check_flag has THREE different accepted value sets depending on the
       rule ('pass' / the relax family / 'pass_e30'). Never match LIKE 'pass%' -
       that conflates all three and over-approves.

   PARAMETERS
     start_date      first application date to include (inclusive).
     end_date        last  application date to include (inclusive). Without this
                     the run would sweep from start_date up to today.
     fat_start_date  how far back to look for FAT / finbox rows. Set a couple of
                     days EARLIER than start_date, because those rows are written
                     before the application completes.

   Audit findings + full changelog:  AUDIT_Scirevawf_21_26August.md
   =========================================================================== */
SET start_date     = '2026-08-21';   /* first application date to include (inclusive) */
SET end_date       = '2026-08-26';   /* last  application date to include (inclusive) */
SET fat_start_date = '2026-08-19';   /* look-back for FAT / finbox rows: ~2 days before start_date */


/* ═══════════════════════════════════════════════════════════════
   STEP 1 — transaction base (Ring only, repeat only)
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: every repeat application on Ring from start_date onward, with its
         loan_reference_number attached.
   WHY : this is the spine - every later step filters down to these txn ids.
   NOTE: platform_user_type = 'repeat' is the repeat-customer filter.
         loan_reference_number IS NULL means the application never became a loan. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_WF AS
SELECT
    a.transaction_reference_number           AS fb_transaction_id,
    a.financier_reference_number,
    NULL                                     AS financier_code,
    a.platform,
    a.platform_user_type,
    DATE(a.created_at)                       AS txn_crdt,
    LOWER(a.user_type)                       AS user_type,
    a.channel,
    a.offer_segment,
    CASE
        WHEN LOWER(a.offer_segment) LIKE '%conc%'  THEN 'Concurrent'
        WHEN LOWER(a.offer_segment) LIKE '%topup%' THEN 'Topup'
        ELSE 'Others'
    END                                      AS offer_category,
    a.sub_product,
    a.status,
    a.rejection_reason,
    a.user_reference_number,
    b.loan_reference_number,
    DATE(b.created_at)                       AS lrn_crdt,
    CASE WHEN a.platform = 'KISSHT' THEN 'K2R' ELSE 'Ring' END AS seg_platform,

    /* ---- amount / tenure come from transaction_vars_grp_v1, NOT bi.transactions ----
       bi.transactions.loan_amount is the dead sentinel -999.00 on every row (verified:
       1 distinct value across 150,769 txns), so anything derived from it was garbage.
       The vars side is filtered to loan_reference_number IS NOT NULL, which makes the
       join exactly 1:1 -- the ~9x fan-out is undisbursed attempts repeating against a
       NULL LRN. Coverage is therefore limited to DISBURSED loans (~12% of the base);
       an undisbursed application legitimately has no loan amount, so loan_amount is
       NULL there and lts_seg falls through to the bare tenure. */
    vars_grp_v1.loan_amount,
    vars_grp_v1.instalment_no_months,
    CASE
        WHEN vars_grp_v1.loan_amount <= 20000 AND vars_grp_v1.instalment_no_months >= 12 THEN 'LTS-12'
        WHEN vars_grp_v1.loan_amount <= 33000 AND vars_grp_v1.instalment_no_months >= 24 THEN 'LTS-24'
        ELSE vars_grp_v1.instalment_no_months::VARCHAR
    END                                      AS lts_seg
FROM ring_SOURCE.BI.TRANSACTIONS a
LEFT JOIN ring_source.bi.loans b ON a.transaction_reference_number = b.transaction_reference_number
LEFT JOIN (
    SELECT loan_reference_number, loan_amount, instalment_no_months
    FROM ring_reports.temp_tables.transaction_vars_grp_v1
    WHERE loan_reference_number IS NOT NULL
) vars_grp_v1
       ON vars_grp_v1.loan_reference_number = b.loan_reference_number
WHERE a.platform_user_type = 'repeat'
  AND DATE(a.created_at) >= $start_date
  AND DATE(a.created_at) <= $end_date
;


/* ═══════════════════════════════════════════════════════════════
   STEP 2 — deduplicated transaction base (Ring only)
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: exactly one row per transaction.
   HOW : the source can hold several rows per txn, so
         QUALIFY ROW_NUMBER() OVER (PARTITION BY txn ORDER BY created_at) = 1
         keeps the earliest one.
   WHY : without this, every later join would multiply rows and inflate counts.
   ALSO: carries lts_seg / tenure_seg through from Step 1. Both are built on
         transaction_vars_grp_v1 values, never on bi.transactions.loan_amount. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_c2_transactions AS
SELECT
    'Ring'                  AS platform,
    lm.seg_platform,
    lm.rejection_reason,
    t.transaction_reference_number AS fb_transaction_id,
    t.status,
    t.sub_product,
    /* amount / tenure carried from Step 1, i.e. from transaction_vars_grp_v1.
       Reading t.loan_amount here would re-introduce the -999 sentinel. */
    lm.loan_amount,
    lm.instalment_no_months,
    lm.offer_category,
    lm.lts_seg,
    CASE
        WHEN lm.loan_amount <= 20000 AND lm.instalment_no_months >= 12 THEN 'LTS-12'
        WHEN lm.loan_amount <= 33000 AND lm.instalment_no_months >= 24 THEN 'LTS-24'
        WHEN lm.instalment_no_months = 12                              THEN '12'
        WHEN lm.instalment_no_months > 12                              THEN '>12'
        ELSE CAST(lm.instalment_no_months AS VARCHAR)
    END                                                             AS tenure_seg,
    lm.user_type,
    t.platform_user_type,
    t.platform_user_type    AS user_type_derived,
    DATE(t.created_at)      AS date,
    t.channel,
    lm.offer_segment,
    lm.financier_reference_number,
    lm.financier_code,
    lm.user_reference_number
FROM kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_WF lm
INNER JOIN ring_source.bi.transactions t
    ON t.transaction_reference_number = lm.fb_transaction_id
QUALIFY ROW_NUMBER() OVER (PARTITION BY t.transaction_reference_number ORDER BY t.created_at) = 1
;


/* ═══════════════════════════════════════════════════════════════
   STEP 2b — finbox pivot (Ring only, extended with new-DT columns)
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: finbox policy variables, reshaped.
   HOW : finbox stores ONE ROW PER VARIABLE (an entity-attribute-value table).
         MAX(CASE WHEN s.name = <modelset> THEN s.OUTPUT__<var> END) pivots that
         into one row per txn with one COLUMN per variable. MAX() is just picking
         the single non-null value, not doing real arithmetic.
   WATCH OUT:
     * s.name is the MODELSET a variable belongs to - 'finbox_variables',
       'repeat_offer_variable', 'offer_computation_variables',
       'new_finbox_variables'. Reading a variable under the wrong modelset
       silently returns NULL for every row, and a NULL usually PASSES the check.
       That failure mode is invisible unless you count non-nulls.
     * experiment_identifier exists as TWO different columns that mean two
       different things. The decision table writes it WITHOUT '.Output', so we
       read OUTPUT__EXPERIMENT_IDENTIFIER (not ..._OUTPUT). Do NOT coalesce them. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_c2_finbox_pivot AS
SELECT
    'Ring'  AS platform,
    s.source_reference_number AS fb_transaction_id,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__users_to_be_blocklisted                    END) AS users_to_be_blocklisted,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__important_checks                           END) AS important_checks,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__risk_check_flag                            END) AS risk_check_flag,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__status                                     END) AS output_status,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__FINAL_PINCODE_RISK_TAG                     END) AS final_pincode_risk_tag,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__EQUIFAX_TOP_OF_THE_FUNNEL_REJECT           END) AS equifax_top_of_the_funnel_reject,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__common_previous_loan_tenure                END) AS common_previous_loan_tenure,
    MAX(CASE WHEN s.name = 'repeat_offer_variable' THEN s.OUTPUT__lts_segment_modify                         END) AS lts_segment_modify,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__user_mobilehash_and_panhash_linkage        END) AS fp_user_mobilehash_and_panhash_linkage,
    /* ── sicreva segment columns ── */
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__shield_rejection_flag                      END) AS shield_rejection_flag,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__shield_android_version_800_810_flag        END) AS shield_android_version_800_810_flag,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__uan_hit_non_salaried_unemp_last_1_yr       END) AS uan_hit_non_salaried_unemp_last_1_yr,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__CROSS_PLATFORM_ONGOING_LT                  END) AS cross_platform_ongoing_lt,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__loan_cross_ongoing_loan_count              END) AS loan_cross_ongoing_loan_count,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__modified_preclosure_days                   END) AS modified_preclosure_days,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__conc_adj_max_emi_cap                       END) AS conc_adj_max_emi_cap,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__v43_location_based_tenure                  END) AS v43_location_based_tenure,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__experiment_identifier                      END) AS experiment_identifier,
    MAX(CASE WHEN s.name = 'repeat_offer_variable' THEN s.OUTPUT__seg_final_input_tenure_v43                 END) AS seg_final_input_tenure_v43,
    MAX(CASE WHEN s.name = 'repeat_offer_variable' THEN s.OUTPUT__final_emi                                  END) AS final_emi,
    /* NEW DT (dt_table (1).csv) col 53: repeat_offer_variable.f2_emi_cap - gates the three _hemi rules */
    MAX(CASE WHEN s.name = 'repeat_offer_variable' THEN s.OUTPUT__f2_emi_cap                                 END) AS f2_emi_cap,
    /* ── NEW-DT columns ── */
    MAX(CASE WHEN s.name IN ('finbox_variables','new_finbox_variables') THEN s.OUTPUT__loan_combined_ongoing_loans_count_onbook END) AS loan_combined_ongoing_loans_count_onbook,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__offer_request_recompute_reason             END) AS offer_request_recompute_reason,
    /* Full-DT additions */
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__aa_mandatory_check                         END) AS aa_mandatory_check,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__bypass_users                               END) AS bypass_users,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__low_propensity_low_leverage_flag           END) AS low_propensity_low_leverage_flag,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__wl_reject_users                            END) AS wl_reject_users,
    MAX(CASE WHEN s.name = 'finbox_variables'      THEN s.OUTPUT__sicreva_wl_tenure                          END) AS sicreva_wl_tenure,
    MAX(CASE WHEN s.name = 'repeat_offer_variable'          THEN s.OUTPUT__rpt_aa_stm_tenure                          END) AS rpt_aa_stm_tenure,
    MAX(CASE WHEN s.name = 'offer_computation_variables'    THEN s.OUTPUT__profile_based_tenure__output               END) AS profile_based_tenure,
    /* derog variables */
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__DEROG_BASED_CATEGORY        END) AS derog_based_category,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__DEROG_BASED_TENURE          END) AS derog_based_tenure,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__FRESH_DEROG_CATEGORY        END) AS fresh_derog_category,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__ABCL_DEROG                  END) AS abcl_derog,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__NAC_DEROG                   END) AS nac_derog,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__SMFG_DEROG                  END) AS smfg_derog,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__PCHFL_DEROG                 END) AS pchfl_derog,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__MAS_DEROG                   END) AS mas_derog,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__VCL_DEROG                   END) AS vcl_derog,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__IDCCR_FRESH_DEROG_REJECTION END) AS idccr_fresh_derog_rejection,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__IDCCR_REPEAT_DEROG_REJECTION END) AS idccr_repeat_derog_rejection,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__LAP_DEROGS_FLAG             END) AS lap_derogs_flag,
    MAX(CASE WHEN s.name = 'finbox_variables' THEN s.OUTPUT__AA_INCOME                   END) AS aa_income
FROM RING_SOURCE.DOCUMENT_DB.FINBOX_DATA_MODEL_OUTPUT_SPLIT s
WHERE s.name IN ('finbox_variables', 'new_finbox_variables', 'repeat_offer_variable', 'offer_computation_variables')
  AND DATE(s.created_at) >= $fat_start_date
  AND s.source_reference_number IN (
      SELECT fb_transaction_id
      FROM kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_WF
  )
GROUP BY s.source_reference_number
;


/* ═══════════════════════════════════════════════════════════════
   STEP 2c — automation_scoring v43 fallback (Ring only)
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: a BACKUP source for the v43 repeat model score.
   WHY : sagemaker_repeat_v43 in FAT is sometimes missing. Step 5 reads
         COALESCE(FAT score, this score) so a merely-missing score does not get
         reported as a policy failure. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_c5 AS
WITH base AS (
    SELECT
        id                  AS fb_transaction_id,
        model_score,
        model_bands         AS v43_band
    FROM ring_reports.temp_tables.automation_scoring
    WHERE id IN (
        SELECT fb_transaction_id
        FROM kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_WF
    )
      AND model_version = 'V43'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY uploaded_at DESC) = 1
)
SELECT
    a.fb_transaction_id,
    b.model_score           AS auto_model_score,
    b.v43_band              AS auto_v43_band
FROM kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_WF a
LEFT JOIN base b
    ON a.fb_transaction_id = b.fb_transaction_id
;


/* ═══════════════════════════════════════════════════════════════
   STEP 2d — Equifax IDCCR snapshot per Ring txn (ported from LCD funnel)
   URN -> pan_hash (ring_source.mysql.users) -> latest Equifax IDCCR pull
   from ring_source.document_db.bureau_equifax_idccr_data.
   Used downstream to compute the *exact* equifax_check when the app
   was rejected with an equifax reason (buckets Check1/2/3, per
   09_equifax_rejection_validation.sql).
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: the customer's Equifax bureau snapshot.
   HOW : transaction -> user_reference_number -> pan_hash -> latest Equifax pull.
   WHY : when the app just says "rejected for equifax", this lets us name the
         actual bureau reason (Check1 / Check2 / Check3) instead of a generic label. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_c2_eqfx AS
WITH u AS (
    SELECT user_reference_number AS urn, pan_hash
    FROM ring_source.mysql.users
    WHERE pan_hash IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY user_reference_number ORDER BY user_id DESC) = 1
),
e AS (
    SELECT
        identification_hash_value                     AS pan_hash,
        idccr_variables__score                        AS score,
        idccr_variables__vintage                      AS vintage,
        idccr_variables__months_since_90dpd           AS mn_since_90dpd,
        idccr_variables__live_loans_overdue_sum       AS live_overdue,
        idccr_variables__mfi_score                    AS mfi_score,
        idccr_variables__mfi_live_loan_count          AS mfi_live_cnt,
        idccr_variables__mfi_live_loans_overdue_sum   AS mfi_overdue
    FROM ring_source.document_db.bureau_equifax_idccr_data
    QUALIFY ROW_NUMBER() OVER (PARTITION BY identification_hash_value ORDER BY created_at DESC) = 1
)
SELECT
    lm.fb_transaction_id,
    u.pan_hash,
    e.score, e.vintage, e.mn_since_90dpd, e.live_overdue,
    e.mfi_score, e.mfi_live_cnt, e.mfi_overdue
FROM kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_WF lm
LEFT JOIN u ON u.urn = lm.user_reference_number
LEFT JOIN e ON e.pan_hash = u.pan_hash
QUALIFY ROW_NUMBER() OVER (PARTITION BY lm.fb_transaction_id ORDER BY e.score DESC NULLS LAST) = 1
;


/* ═══════════════════════════════════════════════════════════════
   STEP 3 — Ring FAT
   Uses digi_multi_platform_cabal_count (new DT variable name).
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: the FAT ("feature at time") variables - age, DPD history, bureau fields,
         model scores. One row per transaction, latest row wins.
   WATCH OUT:
     * every column here is stored as TEXT, so numeric comparisons rely on
       implicit casts. Prefer TRY_TO_DOUBLE if you add new ones.
     * -1 in months_since_last_0_dpd / _90_dpd means "never had DPD" (a GOOD
       thing). We remap it to 999 right here, so downstream "> 3" and ">= 12"
       tests just work and nobody has to remember the sentinel.
     * v43_model_band = 100 means UNSCORED (score missing or <= 0). It is a
       coverage gap, NOT the worst decile. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_c2_fat AS
SELECT
    'Ring'  AS platform,
    f.module,
    f.source_reference_number                                           AS fb_transaction_id,
    f.common_age,
    f.bureau_cibil_3_score,
    f.bureau_cibil_3_bureau_vintage,
    f.bureau_cibil_3_live_loans_overdue_amount_noncc,
    f.bureau_cibil_3_live_loans_overdue_amount,
    f.bureau_cibil_3_no_of_suit_filed,
    f.bureau_cibil_3_write_off_amount,
    f.bureau_cibil_3_write_off_past_12months,
    f.bureau_cibil_3_live_non_agri_cc_gl_sicreva_15k_count,
    f.bureau_cibil_3_diff_num_concurrent_live_loans_m0m2_m6m8_non_cc_gl_agri_sicreva_15k,
    f.bureau_cibil_3_unsecured_enquiries_in_last_1_mon,
    /* Normalize -1 (never-DPD sentinel) → 999 so > / >= comparisons pass naturally.
       NULL stays NULL and is handled downstream with NVL. */
    CASE WHEN f.bureau_cibil_3_months_since_last_90_dpd = -1 THEN 999
         ELSE f.bureau_cibil_3_months_since_last_90_dpd END                     AS bureau_cibil_3_months_since_last_90_dpd,
    CASE WHEN f.bureau_cibil_3_months_since_last_0_dpd  = -1 THEN 999
         ELSE f.bureau_cibil_3_months_since_last_0_dpd  END                     AS bureau_cibil_3_months_since_last_0_dpd,
    f.sagemaker_global_v34,
    f.sagemaker_repeat_v43,
    CASE
        WHEN f.sagemaker_repeat_v43 IS NULL OR f.sagemaker_repeat_v43 <= 0  THEN 100
        WHEN f.sagemaker_repeat_v43 <= 0.04583898 THEN 1
        WHEN f.sagemaker_repeat_v43 <= 0.05716513 THEN 2
        WHEN f.sagemaker_repeat_v43 <= 0.06721260 THEN 3
        WHEN f.sagemaker_repeat_v43 <= 0.07711690 THEN 4
        WHEN f.sagemaker_repeat_v43 <= 0.08767910 THEN 5
        WHEN f.sagemaker_repeat_v43 <= 0.09941131 THEN 6
        WHEN f.sagemaker_repeat_v43 <= 0.11359497 THEN 7
        WHEN f.sagemaker_repeat_v43 <= 0.13267719 THEN 8
        WHEN f.sagemaker_repeat_v43 <= 0.16511013 THEN 9
        WHEN f.sagemaker_repeat_v43 <= 1           THEN 10
        ELSE 100
    END                                                                 AS v43_model_band,
    f.loan_last_loan_max_dpd,
    f.loan_kissht_max_dpd                                               AS cp_max_dpd,
    f.loan_cross_max_dpd,
    f.loan_last_closed_loan_last_emi_dpd,
    /* NEW DT: multi-platform cabal (replaces digi_cabal_count usage) */
    CAST(f.digi_multi_platform_cabal_count              AS FLOAT)       AS digi_multi_platform_cabal_count,
    CAST(f.digi_multi_platform_cabal_count_last_90_days AS FLOAT)       AS digi_multi_platform_cabal_count_last_90_days,
    /* Keep old digi_cabal_count for downstream reference (raw only) */
    CAST(f.digi_cabal_count              AS FLOAT)                      AS digi_cabal_count,
    CAST(f.digi_cabal_count_last_90_days AS FLOAT)                      AS digi_cabal_count_last_90_days,
    CAST(f.digi_count_loan_overdues_1m   AS FLOAT)                      AS digi_count_loan_overdues_1m,
    CAST(f.digi_emi_bounce_count_1m      AS FLOAT)                      AS digi_emi_bounce_count_1m,
    CAST(f.digi_legal_notice_sms_count   AS FLOAT)                      AS digi_legal_notice_sms_count,
    CAST(f.digi_loan_overdues_sum_1m     AS FLOAT)                      AS digi_loan_overdues_sum_1m,
    f.bureau_cibil_3_is_deceased                                        AS is_deceased,
    f.idccr_mfi_score,
    f.idccr_mfi_live_loans_overdue_sum,
    f.idccr_score,
    f.loan_previous_loan_channel,
    f.common_user_type,
    f.user_mobilehash_and_panhash_linkage,
    /* NEW-DT: whitelist columns (used in the sicreva WL segments and to gate the
       non-WL ultra_power/power families, which require common_is_whitelisted != true). */
    f.common_is_whitelisted,
    f.whitelist_normal_whitelist_whitelist_identifier,
    /* Full-DT additions (needed to evaluate every segment in sicreva DT) */
    f.aa_status,
    f.is_aa_enabled_for_app,
    f.transaction_aa_eligible_status,
    f.ignosis_salary_avgmonthlycredit,
    f.ignosis_gambling_betting_totaltxns,
    f.loan_last_loan_foreclosure_nudge,
    f.sagemaker_global_v28,
    f.sagemaker_global_v41,
    f.user_gross_monthly_salary
FROM ring_source.document_db.fat_flatten_data f
WHERE f.module IN ('SEGMENT', 'FLEXI_OFFER', 'PRE_BUREAU', 'POST_BUREAU', 'FLEXI', 'OFFER')
  AND DATE(f.created_at) >= $fat_start_date
  AND f.source_reference_number IN (
      SELECT fb_transaction_id
      FROM kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_WF
  )
QUALIFY ROW_NUMBER() OVER (PARTITION BY f.source_reference_number ORDER BY f.created_at DESC) = 1
;


/* ═══════════════════════════════════════════════════════════════
   STEP 4 — all flags + raw values (Ring only)
   NEW-DT flags added:
     - seg_multi_cabal_0/1 (new-DT digi_multi_platform_cabal_count thresholds)
     - seg_multi_cabal90d_0 (new-DT last-90-day multi-platform cabal)
     - seg_combined_onbook_lt2 (loan_combined_ongoing_loans_count_onbook < 2 or nil)
     - seg_exp_36m_alt (experiment_identifier IN ('verified_sal_high_credits_lowrisk','AA_Seg'))
     - seg_recompute_upg (offer_request_recompute_reason == 'ELIGIBLE_FOR_OFFER_UPGRADE')
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: joins transactions + finbox + FAT, then emits TWO kinds of column:
           1. seg_* / iop_* / imp_* / r1_risk_*   -> 1/0 PASS flags
           2. rv_*                                -> the raw value, untouched
   WHY : the flags make the 65 rule blocks in Step 5 readable; the rv_* columns
         let us print the number that actually caused a failure.

   HOW TO READ A FLAG NAME
         seg_<variable>_<threshold>
         _0 / _1 / _5 = "<= that number"     ge = ">="     gt = ">"     eq = "=="

   NULL POLICY - IMPORTANT
         Most numeric flags wrap the value as NVL(x, <a passing value>), so a
         MISSING variable counts as a PASS. The real decision table is stricter:
         it allows nil only where the cell literally says "or @ == nil".
         The two readings give different approval counts. See AUDIT section 6.1
         before you trust an absolute number. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.tmp_c2_flags AS
SELECT
    t.platform,
    t.seg_platform,
    f.module,
    t.fb_transaction_id,
    t.user_reference_number,
    t.rejection_reason,
    t.date,
    t.channel,
    t.status,
    t.sub_product,
    t.loan_amount,
    t.instalment_no_months,
    t.tenure_seg,
    t.user_type,
    t.platform_user_type,
    t.user_type_derived,
    t.offer_segment,
    t.financier_reference_number,
    t.financier_code                AS financier_code_raw,

    /* ══════════════════════════════════════════════════════════
       PLAIN ENGLISH: the flags below belong to the OLDER, WIDER *app-level*
       decision table (age 21..59, cibil >= 625, v43 band 1-9, ...). They are
       NOT Sicreva segment conditions. Only app_first_rejection_flag and
       sub_reason use them, as a fallback label when no Sicreva rule fires.
         iop_*     = "input offer policy" gate
         imp_*     = mandatory / "important" check
         r1_risk_* = risk-rule-1 checks
       APP flags (kept as-is, still use old digi_cabal_count) —
       used by app_first_rejection_flag/value only. Untouched.
       ══════════════════════════════════════════════════════════ */
    CASE WHEN f.common_age BETWEEN 21 AND 59                                                                                                      THEN 1 ELSE 0 END AS iop_01_age,
    CASE WHEN NVL(f.digi_cabal_count_last_90_days, 0.0) <= 2.0                                                                                   THEN 1 ELSE 0 END AS iop_02_digi_cabal_90d,
    CASE WHEN NVL(f.digi_count_loan_overdues_1m, 0.0) <= 2.0                                                                                     THEN 1 ELSE 0 END AS iop_03_digi_overdues,
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_90_dpd, 999) > 3                                                                             THEN 1 ELSE 0 END AS iop_04_months_90dpd,
    CASE WHEN NVL(f.bureau_cibil_3_no_of_suit_filed, 0) <= 0                                                                                     THEN 1 ELSE 0 END AS iop_05_suit_filed,
    CASE WHEN LOWER(NVL(CAST(f.bureau_cibil_3_write_off_past_12months AS VARCHAR), 'false')) = 'false'                                           THEN 1 ELSE 0 END AS iop_06_write_off_12m,
    CASE WHEN NVL(CAST(fp.users_to_be_blocklisted AS INT), 0) <> 1                                                                               THEN 1 ELSE 0 END AS iop_07_blocklist,
    CASE WHEN LOWER(NVL(fp.output_status, '')) = 'active'                                                                                        THEN 1 ELSE 0 END AS iop_10_status_active,
    CASE WHEN NVL(CAST(fp.lts_segment_modify AS FLOAT), 0) >= 3                                                                                  THEN 1 ELSE 0 END AS iop_11_lts_segment,
    CASE WHEN NVL(f.v43_model_band, 100) BETWEEN 1 AND 9                                                                                         THEN 1 ELSE 0 END AS iop_12_v43_model_range,

    CASE WHEN NVL(CAST(f.is_deceased AS INT), 0) <> 1                                                                                            THEN 1 ELSE 0 END AS imp_01_not_deceased,
    CASE WHEN f.idccr_mfi_score IS NULL
           OR CAST(f.idccr_mfi_score AS FLOAT) < 300
           OR CAST(f.idccr_mfi_score AS FLOAT) > 600                                                                                             THEN 1 ELSE 0 END AS imp_02_idccr_mfi_score,
    CASE WHEN f.idccr_mfi_live_loans_overdue_sum IS NULL
           OR NVL(CAST(f.idccr_mfi_live_loans_overdue_sum AS FLOAT), 0) <= 0                                                                     THEN 1 ELSE 0 END AS imp_03_idccr_mfi_overdue,
    CASE WHEN NVL(CAST(fp.equifax_top_of_the_funnel_reject AS INT), 0) = 0                                                                       THEN 1 ELSE 0 END AS imp_04_equifax_tof,
    CASE WHEN UPPER(NVL(f.common_user_type, '')) = 'REPEAT'                                                                                      THEN 1 ELSE 0 END AS imp_05_user_type_repeat,
    CASE WHEN UPPER(NVL(fp.final_pincode_risk_tag, '')) <> 'HR3'                                                                                 THEN 1 ELSE 0 END AS imp_06_pincode_risk_tag,

    CASE WHEN f.common_age BETWEEN 21 AND 59                                                                                                      THEN 1 ELSE 0 END AS r1_risk_01_age,
    CASE WHEN NVL(f.loan_last_loan_max_dpd, 0) <= 30                                                                                             THEN 1 ELSE 0 END AS r1_risk_02_loan_max_dpd,
    CASE WHEN NVL(f.loan_last_closed_loan_last_emi_dpd, 0) <= 10                                                                                 THEN 1 ELSE 0 END AS r1_risk_03_last_emi_dpd,
    CASE WHEN NVL(f.cp_max_dpd, 0) <= 90                                                                                                         THEN 1 ELSE 0 END AS r1_risk_04_cp_max_dpd,
    CASE WHEN NVL(f.digi_cabal_count, 0.0) <= 3.0                                                                                                THEN 1 ELSE 0 END AS r1_risk_05_digi_cabal,
    CASE WHEN NVL(f.digi_cabal_count_last_90_days, 0.0) <= 2.0                                                                                   THEN 1 ELSE 0 END AS r1_risk_06_digi_cabal_90d,
    CASE WHEN NVL(f.digi_count_loan_overdues_1m, 0.0) <= 2.0                                                                                     THEN 1 ELSE 0 END AS r1_risk_07_digi_overdues,
    CASE WHEN NVL(f.bureau_cibil_3_score, 0) >= 625                                                                                              THEN 1 ELSE 0 END AS r1_risk_08_cibil_score,
    CASE WHEN NVL(f.bureau_cibil_3_bureau_vintage, 0) >= 3                                                                                       THEN 1 ELSE 0 END AS r1_risk_09_bureau_vintage,
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_90_dpd, 999) >= 3                                                                            THEN 1 ELSE 0 END AS r1_risk_10_months_90dpd,
    CASE WHEN NVL(f.bureau_cibil_3_live_loans_overdue_amount_noncc, 0) <= 30000                                                                  THEN 1 ELSE 0 END AS r1_risk_11_live_overdue,
    CASE WHEN NVL(f.bureau_cibil_3_no_of_suit_filed, 0) <= 0                                                                                     THEN 1 ELSE 0 END AS r1_risk_12_suit_filed,
    CASE WHEN NVL(f.bureau_cibil_3_write_off_amount, 0) <= 0                                                                                     THEN 1 ELSE 0 END AS r1_risk_13_write_off_amount,
    CASE WHEN LOWER(NVL(CAST(f.bureau_cibil_3_write_off_past_12months AS VARCHAR), 'false')) = 'false'                                           THEN 1 ELSE 0 END AS r1_risk_14_write_off_12m,
    CASE WHEN NVL(f.bureau_cibil_3_diff_num_concurrent_live_loans_m0m2_m6m8_non_cc_gl_agri_sicreva_15k, 0) <= 15                                 THEN 1 ELSE 0 END AS r1_risk_15_diff_conc_loans,
    CASE WHEN NVL(f.bureau_cibil_3_live_non_agri_cc_gl_sicreva_15k_count, 0) <= 20                                                               THEN 1 ELSE 0 END AS r1_risk_16_live_non_agri,
    CASE WHEN NVL(f.bureau_cibil_3_unsecured_enquiries_in_last_1_mon, 0) <= 20                                                                   THEN 1 ELSE 0 END AS r1_risk_17_unsec_enq,
    CASE WHEN f.sagemaker_global_v34 > 0 AND f.sagemaker_global_v34 <= 0.285179                                                                  THEN 1 ELSE 0 END AS r1_risk_18_v34_model,
    CASE WHEN NVL(CAST(fp.users_to_be_blocklisted AS INT), 0) <> 1                                                                               THEN 1 ELSE 0 END AS r1_risk_19_blocklist,
    CASE WHEN f.sagemaker_repeat_v43 > 0 AND f.sagemaker_repeat_v43 < 0.16511013                                                                 THEN 1 ELSE 0 END AS r1_risk_20_v43_model,

    /* ══════════════════════════════════════════════════════════
       PLAIN ENGLISH: these ARE the Sicreva decision-table conditions - one flag
       per distinct (variable, threshold) pair used anywhere in dt_table.csv.
       The 65 rule blocks in Step 5 and the three *_waterfall columns are built
       only from these. If you add a threshold to the DT, add a flag here first.
       NEW-DT sicreva segment flags (seg_*)
       Uses digi_multi_platform_cabal_count (from new DT).
       All numeric checks nil-safe via NVL to a passing sentinel.
       ══════════════════════════════════════════════════════════ */

    /* NEW-DT: common_is_whitelisted must be != true for the non-WL segments (ultra_power_*, power_*).
       DT rows for ultra_power/power leave this cell blank, but they sit BELOW the WL rows (7,8)
       which fire on common_is_whitelisted='true'; so a non-WL segment implicitly needs
       common_is_whitelisted <> 'true'. NULL treated as pass. */
    CASE WHEN LOWER(NVL(CAST(f.common_is_whitelisted AS VARCHAR), 'false')) <> 'true'                                                             THEN 1 ELSE 0 END AS seg_not_whitelisted,

    /* status Active */
    CASE WHEN LOWER(NVL(fp.output_status, '')) = 'active'                                                                                        THEN 1 ELSE 0 END AS seg_status_active,

    /* age 24..59 */
    CASE WHEN f.common_age BETWEEN 24 AND 59                                                                                                      THEN 1 ELSE 0 END AS seg_age_24_59,

    /* digi_multi_platform_cabal_count thresholds  (0 or nil) / (<=1 or nil) */
    CASE WHEN NVL(f.digi_multi_platform_cabal_count, 0.0) <= 0.0                                                                                 THEN 1 ELSE 0 END AS seg_multi_cabal_0,
    CASE WHEN NVL(f.digi_multi_platform_cabal_count, 0.0) <= 1.0                                                                                 THEN 1 ELSE 0 END AS seg_multi_cabal_1,

    /* digi_multi_platform_cabal_count_last_90_days <= 0 or nil */
    CASE WHEN NVL(f.digi_multi_platform_cabal_count_last_90_days, 0.0) <= 0.0                                                                    THEN 1 ELSE 0 END AS seg_multi_cabal90d_0,

    /* modified_preclosure_days > 90 or nil */
    CASE WHEN fp.modified_preclosure_days IS NULL
           OR CAST(fp.modified_preclosure_days AS FLOAT) > 90                                                                                    THEN 1 ELSE 0 END AS seg_preclosure_gt90,

    /* digi_emi_bounce_count_1m */
    CASE WHEN NVL(f.digi_emi_bounce_count_1m, 0.0) <= 0.0                                                                                        THEN 1 ELSE 0 END AS seg_emi_bounce_0,
    CASE WHEN NVL(f.digi_emi_bounce_count_1m, 0.0) <= 1.0                                                                                        THEN 1 ELSE 0 END AS seg_emi_bounce_1,

    /* digi_legal_notice_sms_count <= 0 or nil */
    CASE WHEN NVL(f.digi_legal_notice_sms_count, 0.0) <= 0.0                                                                                     THEN 1 ELSE 0 END AS seg_legal_notice_0,

    /* digi_count_loan_overdues_1m */
    CASE WHEN NVL(f.digi_count_loan_overdues_1m, 0.0) <= 0.0                                                                                     THEN 1 ELSE 0 END AS seg_digi_overdues_0,
    CASE WHEN NVL(f.digi_count_loan_overdues_1m, 0.0) <= 1.0                                                                                     THEN 1 ELSE 0 END AS seg_digi_overdues_1,

    /* digi_loan_overdues_sum_1m */
    CASE WHEN NVL(f.digi_loan_overdues_sum_1m, 0.0) <= 0.0                                                                                       THEN 1 ELSE 0 END AS seg_loan_overdues_sum_0,
    CASE WHEN NVL(f.digi_loan_overdues_sum_1m, 0.0) <= 2000.0                                                                                    THEN 1 ELSE 0 END AS seg_loan_overdues_sum_2000,

    /* bureau_cibil_3_months_since_last_0_dpd: '> 3 or == -1' / '> 1 or == -1'
       -1 already remapped to 999 in Step 3, so a simple > check + NULL-safe NVL(...,999) works. */
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_0_dpd, 999) > 3                                                                              THEN 1 ELSE 0 END AS seg_months_0dpd_gt3,
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_0_dpd, 999) > 1                                                                              THEN 1 ELSE 0 END AS seg_months_0dpd_gt1,

    /* bureau_cibil_3_months_since_last_90_dpd >= 12 or -1  (-1 already 999) */
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_90_dpd, 999) >= 12                                                                           THEN 1 ELSE 0 END AS seg_months_90dpd_ge12,

    /* suit filed <= 0 or nil */
    CASE WHEN NVL(f.bureau_cibil_3_no_of_suit_filed, 0) <= 0                                                                                     THEN 1 ELSE 0 END AS seg_suit_filed_0,

    /* write_off_past_12months = FALSE */
    CASE WHEN LOWER(NVL(CAST(f.bureau_cibil_3_write_off_past_12months AS VARCHAR), 'false')) = 'false'                                           THEN 1 ELSE 0 END AS seg_writeoff_12m_false,

    /* final_emi >= 5500 */
    CASE WHEN NVL(CAST(fp.final_emi AS FLOAT), 0) >= 5500                                                                                        THEN 1 ELSE 0 END AS seg_final_emi_5500,

    /* loan_last_loan_max_dpd <= 1 or nil,  <= 4 or nil */
    CASE WHEN NVL(f.loan_last_loan_max_dpd, 0) <= 1                                                                                              THEN 1 ELSE 0 END AS seg_loan_max_dpd_1,
    CASE WHEN NVL(f.loan_last_loan_max_dpd, 0) <= 4                                                                                              THEN 1 ELSE 0 END AS seg_loan_max_dpd_4,

    /* uan_hit != 1 */
    CASE WHEN NVL(CAST(fp.uan_hit_non_salaried_unemp_last_1_yr AS INT), 0) <> 1                                                                  THEN 1 ELSE 0 END AS seg_uan_hit_pass,

    /* loan_last_closed_loan_last_emi_dpd <= 1 or nil */
    CASE WHEN NVL(f.loan_last_closed_loan_last_emi_dpd, 0) <= 1                                                                                  THEN 1 ELSE 0 END AS seg_last_emi_dpd_1,

    /* shield_rejection_flag == 0  (nil treated as pass) */
    CASE WHEN NVL(CAST(fp.shield_rejection_flag AS INT), 0) = 0                                                                                  THEN 1 ELSE 0 END AS seg_shield_rej_pass,

    /* shield_android_version_800_810_flag == 0  (nil treated as pass) */
    CASE WHEN NVL(CAST(fp.shield_android_version_800_810_flag AS INT), 0) = 0                                                                    THEN 1 ELSE 0 END AS seg_shield_android_pass,

    /* users_to_be_blocklisted != 1 */
    CASE WHEN NVL(CAST(fp.users_to_be_blocklisted AS INT), 0) <> 1                                                                               THEN 1 ELSE 0 END AS seg_blocklist_pass,

    /* common_previous_loan_tenure >= 1 */
    CASE WHEN NVL(CAST(fp.common_previous_loan_tenure AS FLOAT), 0) >= 1                                                                         THEN 1 ELSE 0 END AS seg_prev_tenure_ge1,

    /* cross_platform_ongoing_lt == 0  (nil treated as pass — many rows use it, but ==0 strict) */
    CASE WHEN NVL(CAST(fp.cross_platform_ongoing_lt AS INT), 0) = 0                                                                              THEN 1 ELSE 0 END AS seg_cross_lt_0,

    /* bureau_cibil_3_live_loans_overdue_amount <= 2000 or nil */
    CASE WHEN NVL(CAST(f.bureau_cibil_3_live_loans_overdue_amount AS FLOAT), 0) <= 2000                                                          THEN 1 ELSE 0 END AS seg_live_overdue_2000,

    /* important_checks: DT cell is '@ == "pass"' on all gated rules -> strict equality. */
    CASE WHEN LOWER(NVL(fp.important_checks, '')) = 'pass'                                                                                       THEN 1 ELSE 0 END AS seg_important_checks_pass,

    /* risk_check_flag: THREE distinct DT predicates. Do NOT use LIKE 'pass%' -- it conflates
       them and lets pass_e30 satisfy a plain-'pass' rule (audit 3.8). */
    CASE WHEN LOWER(NVL(fp.risk_check_flag, '')) = 'pass'                                                                                        THEN 1 ELSE 0 END AS seg_risk_check_pass,
    CASE WHEN LOWER(NVL(fp.risk_check_flag, '')) IN ('pass','pass_top5mb_relax','pass_top2mb_dpd_relax','pass_aa_top4mb_relax')                   THEN 1 ELSE 0 END AS seg_risk_check_pass_relax,
    CASE WHEN LOWER(NVL(fp.risk_check_flag, '')) = 'pass_e30'                                                                                     THEN 1 ELSE 0 END AS seg_risk_check_pass_e30,

    /* seg_final_input_tenure_v43 thresholds */
    CASE WHEN NVL(CAST(fp.seg_final_input_tenure_v43 AS FLOAT), 0) >= 24                                                                         THEN 1 ELSE 0 END AS seg_tenure_ge24,
    CASE WHEN NVL(CAST(fp.seg_final_input_tenure_v43 AS FLOAT), 0) >= 18                                                                         THEN 1 ELSE 0 END AS seg_tenure_ge18,
    CASE WHEN NVL(CAST(fp.seg_final_input_tenure_v43 AS FLOAT), 0) >= 6                                                                          THEN 1 ELSE 0 END AS seg_tenure_ge6,
    CASE WHEN NVL(CAST(fp.seg_final_input_tenure_v43 AS FLOAT), 0) >= 3                                                                          THEN 1 ELSE 0 END AS seg_tenure_ge3,

    /* idccr_score */
    CASE WHEN NVL(CAST(f.idccr_score AS FLOAT), 0) >= 750                                                                                        THEN 1 ELSE 0 END AS seg_idccr_750,
    CASE WHEN NVL(CAST(f.idccr_score AS FLOAT), 0) >= 700                                                                                        THEN 1 ELSE 0 END AS seg_idccr_700,

    /* final_pincode_risk_tag IN ('LR','MR')  — used for ultra_power_36m_exp */
    CASE WHEN UPPER(NVL(fp.final_pincode_risk_tag, '')) IN ('LR', 'MR')                                                                          THEN 1 ELSE 0 END AS seg_pincode_lr_mr,

    /* experiment_identifier — NEW-DT allows two values for 36m_exp */
    CASE WHEN NVL(fp.experiment_identifier, '') IN ('verified_sal_high_credits_lowrisk', 'AA_Seg')                                               THEN 1 ELSE 0 END AS seg_exp_36m_alt,

    /* conc_adj_max_emi_cap >= 2200 or nil */
    CASE WHEN fp.conc_adj_max_emi_cap IS NULL
           OR CAST(fp.conc_adj_max_emi_cap AS FLOAT) >= 2200                                                                                     THEN 1 ELSE 0 END AS seg_conc_adj_emi_pass,

    /* v43_location_based_tenure */
    CASE WHEN NVL(CAST(fp.v43_location_based_tenure AS INT), 0) = 24                                                                             THEN 1 ELSE 0 END AS seg_loc_tenure_24,
    CASE WHEN NVL(CAST(fp.v43_location_based_tenure AS INT), 0) = 18                                                                             THEN 1 ELSE 0 END AS seg_loc_tenure_18,
    CASE WHEN NVL(CAST(fp.v43_location_based_tenure AS INT), 0) = 12                                                                             THEN 1 ELSE 0 END AS seg_loc_tenure_12,

    /* NEW-DT: loan_combined_ongoing_loans_count_onbook < 2 or nil */
    CASE WHEN fp.loan_combined_ongoing_loans_count_onbook IS NULL
           OR CAST(fp.loan_combined_ongoing_loans_count_onbook AS INT) < 2                                                                       THEN 1 ELSE 0 END AS seg_combined_onbook_lt2,

    /* NEW-DT: offer_request_recompute_reason == 'ELIGIBLE_FOR_OFFER_UPGRADE' (for scr_upg alt rows) */
    CASE WHEN UPPER(NVL(fp.offer_request_recompute_reason, '')) = 'ELIGIBLE_FOR_OFFER_UPGRADE'                                                    THEN 1 ELSE 0 END AS seg_recompute_upg,

    /* ----------------------------------------------------------
       AUDIT FIX 2026-08-28 (audit section 1) - flags referenced by
       ultra_power_waterfall / power_waterfall / best_waterfall that were
       never defined here. Without these the whole script failed to compile
       with "invalid identifier". Thresholds taken from dt_table.csv, NOT
       from the (wrong) values used in the app_first_rejection_flag cascade.
       ---------------------------------------------------------- */

    /* common_age 21..59 */
    CASE WHEN f.common_age BETWEEN 21 AND 59                                                                                                     THEN 1 ELSE 0 END AS seg_age_21_59,

    /* whitelist gates */
    CASE WHEN LOWER(NVL(CAST(f.common_is_whitelisted AS VARCHAR), 'false')) = 'true'                                                              THEN 1 ELSE 0 END AS seg_is_whitelisted,
    CASE WHEN f.whitelist_normal_whitelist_whitelist_identifier = 'WL_RPT_CA31'                                                                  THEN 1 ELSE 0 END AS seg_whitelist_wl_rpt_ca31,

    /* digi_multi_platform_cabal_count <= 5 or nil  (DT rows 10/17/19/20/21/30) */
    CASE WHEN NVL(f.digi_multi_platform_cabal_count, 0.0) <= 5.0                                                                                 THEN 1 ELSE 0 END AS seg_multi_cabal_5,

    /* digi_multi_platform_cabal_count_last_90_days <= 1 or nil */
    CASE WHEN NVL(f.digi_multi_platform_cabal_count_last_90_days, 0.0) <= 1.0                                                                    THEN 1 ELSE 0 END AS seg_multi_cabal90d_1,

    /* digi_count_loan_overdues_1m <= 2 or nil */
    CASE WHEN NVL(f.digi_count_loan_overdues_1m, 0.0) <= 2.0                                                                                     THEN 1 ELSE 0 END AS seg_digi_overdues_2,

    /* loan_last_closed_loan_last_emi_dpd <= 5 or nil */
    CASE WHEN NVL(f.loan_last_closed_loan_last_emi_dpd, 0) <= 5                                                                                  THEN 1 ELSE 0 END AS seg_last_emi_dpd_5,

    /* months_since_last_0_dpd  (-1 already remapped to 999 in Step 3) */
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_0_dpd, 999) > 0                                                                              THEN 1 ELSE 0 END AS seg_months_0dpd_gt0,
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_0_dpd, 999) > 2                                                                              THEN 1 ELSE 0 END AS seg_months_0dpd_gt2,

    /* months_since_last_90_dpd  ('> 3' / '> 6' variants; ge12 already exists) */
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_90_dpd, 999) > 3                                                                             THEN 1 ELSE 0 END AS seg_months_90dpd_gt3,
    CASE WHEN NVL(f.bureau_cibil_3_months_since_last_90_dpd, 999) > 6                                                                             THEN 1 ELSE 0 END AS seg_months_90dpd_gt6,

    /* final_pincode_risk_tag IN ('LR','MR','HR1')  - ultra_power_24m_exp / best_scr_upg */
    CASE WHEN UPPER(NVL(fp.final_pincode_risk_tag, '')) IN ('LR', 'MR', 'HR1')                                                                   THEN 1 ELSE 0 END AS seg_pincode_lr_mr_hr1,

    /* idccr_score cuts actually present in the DT */
    CASE WHEN NVL(CAST(f.idccr_score AS FLOAT), 0) >= 725                                                                                        THEN 1 ELSE 0 END AS seg_idccr_725,
    CASE WHEN NVL(CAST(f.idccr_score AS FLOAT), 0) >= 720                                                                                        THEN 1 ELSE 0 END AS seg_idccr_720,
    CASE WHEN NVL(CAST(f.idccr_score AS FLOAT), 0) >= 680                                                                                        THEN 1 ELSE 0 END AS seg_idccr_680,

    /* experiment_identifier - 24m_exp allows FOUR values (DT csv line 17) */
    CASE WHEN NVL(fp.experiment_identifier, '') IN ('Exp_cash_flow_seg', 'Exp_bureau_seg', 'verified_sal_high_credits_lowrisk', 'AA_Seg')         THEN 1 ELSE 0 END AS seg_exp_24m_alt,
    CASE WHEN NVL(fp.experiment_identifier, '') = 'AA_Seg'                                                                                       THEN 1 ELSE 0 END AS seg_exp_aa_seg,

    /* v43_location_based_tenure - DT uses '== 24' on ONE row and '>= N' on the rest */
    CASE WHEN NVL(CAST(fp.v43_location_based_tenure AS INT), 0) =  24                                                                             THEN 1 ELSE 0 END AS seg_loc_tenure_eq24,
    CASE WHEN NVL(CAST(fp.v43_location_based_tenure AS INT), 0) >= 24                                                                             THEN 1 ELSE 0 END AS seg_loc_tenure_ge24,
    CASE WHEN NVL(CAST(fp.v43_location_based_tenure AS INT), 0) >= 18                                                                             THEN 1 ELSE 0 END AS seg_loc_tenure_ge18,
    CASE WHEN NVL(CAST(fp.v43_location_based_tenure AS INT), 0) >= 12                                                                             THEN 1 ELSE 0 END AS seg_loc_tenure_ge12,

    /* seg_final_input_tenure_v43 - ge9 / ge12 (ge3/6/18/24 already exist) */
    CASE WHEN NVL(CAST(fp.seg_final_input_tenure_v43 AS FLOAT), 0) >= 12                                                                         THEN 1 ELSE 0 END AS seg_tenure_ge12,
    CASE WHEN NVL(CAST(fp.seg_final_input_tenure_v43 AS FLOAT), 0) >= 9                                                                          THEN 1 ELSE 0 END AS seg_tenure_ge9,

    /* lts_segment_modify == 24 */
    CASE WHEN NVL(CAST(fp.lts_segment_modify AS FLOAT), 0) = 24                                                                                  THEN 1 ELSE 0 END AS seg_lts_modify_24,

    /* offer_computation_variables.profile_based_tenure.Output */
    CASE WHEN NVL(CAST(fp.profile_based_tenure AS FLOAT), 0) >= 24                                                                               THEN 1 ELSE 0 END AS seg_profile_tenure_ge24,
    CASE WHEN NVL(CAST(fp.profile_based_tenure AS FLOAT), 0) >= 18                                                                               THEN 1 ELSE 0 END AS seg_profile_tenure_ge18,
    CASE WHEN NVL(CAST(fp.profile_based_tenure AS FLOAT), 0) >= 12                                                                               THEN 1 ELSE 0 END AS seg_profile_tenure_ge12,

    /* NEW DT col 53: repeat_offer_variable.f2_emi_cap >= 12000 - the ONLY condition that
       separates the three _hemi rules (dt 8/10/17) from the rules directly below them. */
    CASE WHEN NVL(CAST(fp.f2_emi_cap AS FLOAT), 0) >= 12000                                                                                   THEN 1 ELSE 0 END AS seg_f2_emi_cap_12000,

    /* seg_status_inactive / seg_loan_overdues_sum_1000 / seg_multi_cabal90d_2 /
       seg_live_overdue_5000 lived here for best_digifail_lrc (dt 55) and best_lowts_lrc
       (dt 56). Both gate finbox_variables.status == 'Inactive' and were removed on
       2026-08-31 along with dt 1/3/4/5, so these flags went with them. */

    /* repeat_offer_variable.rpt_aa_stm_tenure (DT col 50) - the seg_aast_tenure_ge12/18/24
       flags that lived here were referenced ONLY by the three *_aast_upg rules, which were
       removed on 2026-08-31. Dropped with them. The raw value survives as rv_rpt_aa_stm_tenure. */

    /* DT-required but not yet referenced by any waterfall - needed when the granular
       cascades are extended to the remaining 43 segments (audit section 7). */
    CASE WHEN NVL(f.bureau_cibil_3_write_off_amount, 0) <= 0                                                                                     THEN 1 ELSE 0 END AS seg_writeoff_amt_0,
    CASE WHEN NVL(CAST(fp.low_propensity_low_leverage_flag AS INT), 0) = 0                                                                       THEN 1 ELSE 0 END AS seg_low_prop_0,
    CASE WHEN NVL(CAST(fp.low_propensity_low_leverage_flag AS INT), 0) = 1                                                                       THEN 1 ELSE 0 END AS seg_low_prop_1,

    /* rv_* = the raw value, no threshold applied. Two uses:
         1. the 65 rule blocks in Step 5 test rv_* directly
         2. app_first_rejection_value prints 'variable=value' from them */
    /* ── Raw values (kept for value pass-through / rejection value) ── */
    f.common_age                                                                                                                                 AS rv_common_age,
    f.loan_last_loan_max_dpd                                                                                                                     AS rv_loan_last_loan_max_dpd,
    f.loan_last_closed_loan_last_emi_dpd                                                                                                         AS rv_loan_last_closed_loan_last_emi_dpd,
    f.cp_max_dpd                                                                                                                                 AS rv_cp_max_dpd,
    f.loan_cross_max_dpd                                                                                                                         AS rv_loan_cross_max_dpd,
    f.digi_cabal_count                                                                                                                           AS rv_digi_cabal_count,
    f.digi_cabal_count_last_90_days                                                                                                              AS rv_digi_cabal_count_last_90_days,
    f.digi_multi_platform_cabal_count                                                                                                            AS rv_digi_multi_platform_cabal_count,
    f.digi_multi_platform_cabal_count_last_90_days                                                                                               AS rv_digi_multi_platform_cabal_count_last_90_days,
    f.digi_count_loan_overdues_1m                                                                                                                AS rv_digi_count_loan_overdues_1m,
    f.bureau_cibil_3_score                                                                                                                       AS rv_bureau_cibil_3_score,
    f.bureau_cibil_3_bureau_vintage                                                                                                              AS rv_bureau_cibil_3_bureau_vintage,
    f.bureau_cibil_3_months_since_last_90_dpd                                                                                                    AS rv_months_since_last_90_dpd,
    f.bureau_cibil_3_live_loans_overdue_amount_noncc                                                                                             AS rv_live_loans_overdue_amount_noncc,
    f.bureau_cibil_3_no_of_suit_filed                                                                                                            AS rv_no_of_suit_filed,
    f.bureau_cibil_3_write_off_amount                                                                                                            AS rv_write_off_amount,
    CAST(f.bureau_cibil_3_write_off_past_12months AS VARCHAR)                                                                                    AS rv_write_off_past_12months,
    f.bureau_cibil_3_diff_num_concurrent_live_loans_m0m2_m6m8_non_cc_gl_agri_sicreva_15k                                                         AS rv_diff_conc_loans,
    f.bureau_cibil_3_live_non_agri_cc_gl_sicreva_15k_count                                                                                       AS rv_live_non_agri_count,
    f.bureau_cibil_3_unsecured_enquiries_in_last_1_mon                                                                                           AS rv_unsecured_enquiries_1m,
    f.sagemaker_global_v34                                                                                                                       AS rv_sagemaker_global_v34,
    CAST(fp.users_to_be_blocklisted AS INT)                                                                                                      AS rv_users_to_be_blocklisted,
    f.sagemaker_repeat_v43                                                                                                                       AS rv_sagemaker_repeat_v43,
    CAST(f.is_deceased AS INT)                                                                                                                   AS rv_is_deceased,
    CAST(f.idccr_mfi_score AS FLOAT)                                                                                                             AS rv_idccr_mfi_score,
    CAST(f.idccr_mfi_live_loans_overdue_sum AS FLOAT)                                                                                            AS rv_idccr_mfi_live_loans_overdue_sum,
    CAST(fp.equifax_top_of_the_funnel_reject AS INT)                                                                                             AS rv_equifax_top_of_the_funnel_reject,
    f.common_user_type                                                                                                                           AS rv_common_user_type,
    fp.final_pincode_risk_tag                                                                                                                    AS rv_final_pincode_risk_tag,
    CAST(fp.fp_user_mobilehash_and_panhash_linkage AS VARCHAR)                                                                                   AS rv_fp_mobilehash_panhash,
    CAST(fp.lts_segment_modify AS FLOAT)                                                                                                         AS rv_lts_segment_modify,
    f.v43_model_band                                                                                                                             AS rv_v43_model,
    LOWER(NVL(fp.output_status, ''))                                                                                                             AS rv_output_status,
    CAST(f.bureau_cibil_3_live_loans_overdue_amount AS FLOAT)                                                                                    AS rv_live_loans_overdue_amount,
    CAST(fp.common_previous_loan_tenure AS FLOAT)                                                                                                AS rv_common_previous_loan_tenure,
    f.digi_emi_bounce_count_1m                                                                                                                   AS rv_digi_emi_bounce_count_1m,
    f.digi_legal_notice_sms_count                                                                                                                AS rv_digi_legal_notice_sms_count,
    f.digi_loan_overdues_sum_1m                                                                                                                  AS rv_digi_loan_overdues_sum_1m,
    CAST(f.idccr_score AS FLOAT)                                                                                                                 AS rv_idccr_score,
    CAST(fp.final_emi AS FLOAT)                                                                                                                  AS rv_final_emi,
    CAST(fp.f2_emi_cap AS FLOAT)                                                                                                                 AS rv_f2_emi_cap,
    CAST(fp.seg_final_input_tenure_v43 AS FLOAT)                                                                                                 AS rv_seg_final_input_tenure_v43,
    CAST(fp.modified_preclosure_days AS FLOAT)                                                                                                   AS rv_modified_preclosure_days,
    CAST(fp.loan_cross_ongoing_loan_count AS INT)                                                                                                AS rv_loan_cross_ongoing_loan_count,
    CAST(fp.conc_adj_max_emi_cap AS FLOAT)                                                                                                       AS rv_conc_adj_max_emi_cap,
    CAST(fp.v43_location_based_tenure AS INT)                                                                                                    AS rv_v43_location_based_tenure,
    f.bureau_cibil_3_months_since_last_0_dpd                                                                                                     AS rv_months_since_last_0_dpd,
    f.loan_previous_loan_channel                                                                                                                 AS rv_loan_previous_loan_channel,
    fp.experiment_identifier                                                                                                                     AS rv_experiment_identifier,
    fp.important_checks                                                                                                                          AS rv_important_checks,
    fp.risk_check_flag                                                                                                                           AS rv_risk_check_flag,
    CAST(fp.loan_combined_ongoing_loans_count_onbook AS INT)                                                                                     AS rv_loan_combined_ongoing_loans_count_onbook,
    fp.offer_request_recompute_reason                                                                                                            AS rv_offer_request_recompute_reason,
    CAST(fp.uan_hit_non_salaried_unemp_last_1_yr AS INT)                                                                                         AS rv_uan_hit_non_salaried_unemp_last_1_yr,
    CAST(fp.shield_rejection_flag AS INT)                                                                                                        AS rv_shield_rejection_flag,
    CAST(fp.shield_android_version_800_810_flag AS INT)                                                                                          AS rv_shield_android_version_800_810_flag,
    CAST(fp.cross_platform_ongoing_lt AS INT)                                                                                                    AS rv_cross_platform_ongoing_lt,
    CAST(f.common_is_whitelisted AS VARCHAR)                                                                                                     AS rv_common_is_whitelisted,
    f.whitelist_normal_whitelist_whitelist_identifier                                                                                             AS rv_whitelist_identifier,
    /* Full-DT extras (from FAT) */
    f.aa_status                                                                                                                                   AS rv_aa_status,
    f.is_aa_enabled_for_app                                                                                                                       AS rv_is_aa_enabled_for_app,
    f.transaction_aa_eligible_status                                                                                                              AS rv_transaction_aa_eligible_status,
    CAST(f.ignosis_salary_avgmonthlycredit AS FLOAT)                                                                                              AS rv_ignosis_salary_avgmonthlycredit,
    CAST(f.ignosis_gambling_betting_totaltxns AS FLOAT)                                                                                           AS rv_ignosis_gambling_betting_totaltxns,
    CAST(f.loan_last_loan_foreclosure_nudge AS VARCHAR)                                                                                           AS rv_loan_last_loan_foreclosure_nudge,
    f.sagemaker_global_v28                                                                                                                        AS rv_sagemaker_global_v28,
    f.sagemaker_global_v41                                                                                                                        AS rv_sagemaker_global_v41,
    /* Full-DT extras (from finbox pivot) */
    fp.aa_mandatory_check                                                                                                                         AS rv_aa_mandatory_check,
    CAST(fp.bypass_users AS INT)                                                                                                                  AS rv_bypass_users,
    CAST(fp.low_propensity_low_leverage_flag AS INT)                                                                                              AS rv_low_propensity_low_leverage_flag,
    CAST(fp.wl_reject_users AS INT)                                                                                                               AS rv_wl_reject_users,
    CAST(fp.sicreva_wl_tenure AS FLOAT)                                                                                                           AS rv_sicreva_wl_tenure,
    CAST(fp.profile_based_tenure AS FLOAT)                                                                                                        AS rv_profile_based_tenure,
    CAST(fp.rpt_aa_stm_tenure AS FLOAT)                                                                                                           AS rv_rpt_aa_stm_tenure,
    t.user_reference_number                                                                                                                       AS rv_user_reference_number,
    /* derog raw values */
    fp.derog_based_category                                                                                                                      AS rv_derog_based_category,
    fp.derog_based_tenure                                                                                                                        AS rv_derog_based_tenure,
    fp.fresh_derog_category                                                                                                                      AS rv_fresh_derog_category,
    fp.abcl_derog                                                                                                                                AS rv_abcl_derog,
    fp.nac_derog                                                                                                                                 AS rv_nac_derog,
    fp.smfg_derog                                                                                                                                AS rv_smfg_derog,
    fp.pchfl_derog                                                                                                                               AS rv_pchfl_derog,
    fp.mas_derog                                                                                                                                 AS rv_mas_derog,
    fp.vcl_derog                                                                                                                                 AS rv_vcl_derog,
    fp.idccr_fresh_derog_rejection                                                                                                               AS rv_idccr_fresh_derog_rejection,
    fp.idccr_repeat_derog_rejection                                                                                                              AS rv_idccr_repeat_derog_rejection,
    fp.lap_derogs_flag                                                                                                                           AS rv_lap_derogs_flag,
    fp.aa_income                                                                                                                                 AS rv_aa_income,
    f.user_gross_monthly_salary                                                                                                                  AS rv_user_gross_monthly_salary

FROM kissht_reports.temp_tables.tmp_c2_transactions      t
LEFT JOIN kissht_reports.temp_tables.tmp_c2_finbox_pivot fp
    ON fp.fb_transaction_id = t.fb_transaction_id
LEFT JOIN kissht_reports.temp_tables.tmp_c2_fat           f
    ON f.fb_transaction_id  = t.fb_transaction_id
;


/* ═══════════════════════════════════════════════════════════════
   STEP 5 — FINAL SELECT
   ═══════════════════════════════════════════════════════════════ */
/* WHAT: the reportable table. Each column below is a different way of asking
         "what happened to this application".
   NOTE: app_first_rejection_flag and sub_reason are near-identical TWINS - both
         are "did ANY of the 59 rules fire?" followed by the same fallback label
         cascade. If you change a rule, you must change BOTH. */
CREATE OR REPLACE TABLE kissht_reports.temp_tables.wf_21_07_output AS
SELECT
    a.platform,
    a.seg_platform,
    a.module,
    a.fb_transaction_id,
    a.user_reference_number,
    a.status,
    a.date,
    a.sub_product,
    a.loan_amount,
    a.instalment_no_months,
    a.tenure_seg,
    a.user_type,
    a.platform_user_type,
    a.user_type_derived,
    a.channel,
    a.offer_segment,
    a.financier_code_raw                                     AS financier_code,
    a.rejection_reason,

    /* ── rejection_stage ── */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'          THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'  THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                     THEN '2.POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER') THEN '4_FLEXI_OFFER_SEGMENT'
        ELSE '5_DENIED_2'
    END AS rejection_stage,

    /* ══════════════════════════════════════════════════════════
       app_first_rejection_flag — WIDER APP-LEVEL cascade.
       Uses the master app DT (age 21..59, cibil>=625, v43 band 1-9, ...),
       NOT the narrow sicreva ultra_power/power intersection. Users declined
       by ultra_power/power specifics (age 24..59, digi_multi_cabal, preclosure,
       emi_bounce) may still be approved by broader segments (best_1, good_12m,
       i_o_repeat_*, ...) — those approvals should be reflected here.

       The whitelist gate is preserved at the top: whitelisted users still get
       IMP_00_common_is_whitelisted so you can tell them apart from cascade approvals.
       ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'          THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'  THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                     THEN '3_POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            /* =================================================================
               HOW TO READ THE NEXT ~1600 LINES
               =================================================================
               It is ONE big expression:
                     ( block1 ) OR ( block2 ) OR ... OR ( block59 )

               * Each block = one row of dt_table (1).csv, tagged  /@ dt N: <segment> @/
                 where N is that row's 1-based position in the DT.
               * Inside a block, every AND is one NON-BLANK cell of that row,
                 emitted in DT COLUMN order. A cell the DT left blank has no AND here.
               * If ANY block is true, the customer qualified for SOME segment,
                 so the answer short-circuits to 'Approved'.
               * Blocks are in exact dt_table (1).csv order, top to bottom.
                 The dt numbering SKIPS 23, 34 and 54 - those are the three
                 *_aast_upg rows, and 1/3/4/5/55/56 - the six rows gating
                 finbox_variables.status == 'Inactive'. Both sets removed
                 2026-08-31. 68 DT rows - 3 - 6 = 59 blocks.
               * Five segment names appear on two DT rows each (dt 20/21, 31/32,
                 41/57, 61/62, 64/65) - faithful to the table, not a duplicate bug.
               * dt 8, 10 and 17 are the _hemi rows: each is an exact clone of the
                 rule directly below it plus  f2_emi_cap >= 12000  (DT col 53).

               LIMITATION: because this is one flat OR, it tells you IF the
               customer qualified, never WHICH variable blocked them. For that,
               use the *_waterfall columns near the bottom of this file.
               ================================================================= */
            /* ── ANY-SEGMENT CHECK: user is app-approved if they match ANY offer_segment
               in the sicreva DT (all 59 live rows of dt_table (1).csv). If yes,
               short-circuit to 'Approved'. Otherwise fall through to the app-DT reason
               cascade so we can still surface why. ── */
            CASE
                WHEN (
      /* dt 2: si_r_cug_testing */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND (a.rv_user_reference_number = 'IDEP631588977332GZ1P')
      )
     OR       /* dt 6: si_repeat_wl_pq_segment */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND (NVL(a.rv_write_off_amount, 0) <= 0 OR NVL(a.rv_write_off_amount, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (a.rv_whitelist_identifier = 'ABCL_PAPQ')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_wl_reject_users, 0) = 0)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 7: si_wl_low_ir_pf_experiment_segment */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND (NVL(a.rv_write_off_amount, 0) <= 0 OR NVL(a.rv_write_off_amount, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (a.rv_whitelist_identifier = 'CA_POOL_PR_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 8: si_new_repeat_strategy_ultra_power_36m_hemi */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 725)
                     AND (NVL(a.rv_experiment_identifier, '') = 'verified_sal_high_credits_lowrisk' OR NVL(a.rv_experiment_identifier, '') = 'AA_Seg')
                     AND (NVL(a.rv_f2_emi_cap, 0) >= 12000)                                          /* NEW DT col 53: the only check that separates _hemi */
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 9: si_new_repeat_strategy_ultra_power_36m_exp */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 725)
                     AND (NVL(a.rv_experiment_identifier, '') = 'verified_sal_high_credits_lowrisk' OR NVL(a.rv_experiment_identifier, '') = 'AA_Seg')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 10: si_new_repeat_strategy_ultra_power_24m_hemi */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'WL_RPT_CA31')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) = 24)
                     AND (NVL(a.rv_f2_emi_cap, 0) >= 12000)                                          /* NEW DT col 53: the only check that separates _hemi */
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 11: si_new_repeat_strategy_wl_ultra_power_scr_upg */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'WL_RPT_CA31')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) = 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 12: si_lt_repeat_wl_24m_ca_lpf_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 13: si_lt_repeat_wl_24m_lowpricing_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 14: si_lt_repeat_wl_24m_ca_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 15: si_lt_repeat_wl_24m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 0)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 16: si_lt_repeat_wl_24m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 1)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 17: si_new_repeat_strategy_ultra_power_24m_hemi */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 2 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 720)
                     AND (NVL(a.rv_experiment_identifier, '') IN ('Exp_cash_flow_seg', 'Exp_bureau_seg', 'verified_sal_high_credits_lowrisk', 'AA_Seg'))
                     AND (NVL(a.rv_f2_emi_cap, 0) >= 12000)                                          /* NEW DT col 53: the only check that separates _hemi */
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 18: si_new_repeat_strategy_ultra_power_24m_exp */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 2 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 720)
                     AND (NVL(a.rv_experiment_identifier, '') IN ('Exp_cash_flow_seg', 'Exp_bureau_seg', 'verified_sal_high_credits_lowrisk', 'AA_Seg'))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 19: si_new_repeat_strategy_ultra_power_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 20: si_new_repeat_strategy_ultra_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 21: si_new_repeat_strategy_ultra_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 18)
                     AND (UPPER(NVL(a.rv_offer_request_recompute_reason,'')) = 'ELIGIBLE_FOR_OFFER_UPGRADE')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 22: si_new_repeat_strategy_ultra_power_pbt_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_profile_based_tenure, 0) >= 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 24: si_new_repeat_strategy_wl_power_scr_upg */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'WL_RPT_CA31')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 18)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 25: si_lt_repeat_wl_18m_ca_lpf_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 26: si_lt_repeat_wl_18m_lowpricing_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 27: si_lt_repeat_wl_18m_ca_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 28: si_lt_repeat_wl_18m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 0)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 29: si_lt_repeat_wl_18m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 1)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 30: si_new_repeat_strategy_power_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 31: si_new_repeat_strategy_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 18)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 32: si_new_repeat_strategy_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 12)
                     AND (UPPER(NVL(a.rv_offer_request_recompute_reason,'')) = 'ELIGIBLE_FOR_OFFER_UPGRADE')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 33: si_new_repeat_strategy_power_pbt_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (NVL(a.rv_profile_based_tenure, 0) >= 18)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 35: si_lt_repeat_wl_12m_ca_lpf_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 36: si_lt_repeat_wl_12m_lowpricing_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 37: si_lt_repeat_wl_12m_ca_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 38: si_lt_repeat_wl_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 0)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 39: si_lt_repeat_wl_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 1)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 40: si_new_repeat_strategy_best_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 41: si_new_repeat_strategy_best_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 42: si_new_repeat_strategy_best_aascr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_experiment_identifier, '') = 'AA_Seg')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 43: si_new_repeat_strategy_best_pbt_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_profile_based_tenure, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 44: si_lt_repeat_ca_lpf_wl_good_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 45: si_lt_repeat_lowpricing_wl_good_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 46: si_lt_repeat_ca_wl_good_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 47: si_lt_repeat_wl_good_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 48: si_new_repeat_strategy_good_12m */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 49: si_lt_repeat_ca_lpf_wl_standard_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 50: si_lt_repeat_lowpricing_wl_standard_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 51: si_lt_repeat_ca_wl_standard_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 52: si_lt_repeat_wl_standard_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 53: si_new_repeat_strategy_standard_12m */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 57: si_new_repeat_strategy_best_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 2 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.07711690))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_lts_segment_modify, 0) = 24)
                     AND (UPPER(NVL(a.rv_offer_request_recompute_reason,'')) = 'ELIGIBLE_FOR_OFFER_UPGRADE')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 58: si_i_o_repeat_24m */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 2 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.07711690))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_lts_segment_modify, 0) = 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 59: si_i_o_repeat_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) = 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 60: si_i_o_repeat_wl_e30_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 15)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.0467364))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 61: si_i_o_repeat_2 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.09941131))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) >= 6)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
              /* AUDIT FIX 2026-08-28: dt_table.csv line 61 - the 2nd si_i_o_repeat_2 row, previously
                 absent. Tighter v43 cut, and NO months_0dpd / prev_tenure / lts_segment_modify gates. */
     OR       /* dt 62: si_i_o_repeat_2 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.06721260))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) IN ('pass','pass_top5mb_relax','pass_top2mb_dpd_relax','pass_aa_top4mb_relax'))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 63: si_i_o_repeat_wl_e30_2 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 15)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.058347))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 64: si_i_o_repeat_3 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.09941131))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) >= 6)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
              /* AUDIT FIX 2026-08-28: dt_table.csv line 64 - the 2nd si_i_o_repeat_3 row, previously
                 absent. Same v43 cut as its twin but NO prev_tenure / lts_segment_modify gates. */
     OR       /* dt 65: si_i_o_repeat_3 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.09941131))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) IN ('pass','pass_top5mb_relax','pass_top2mb_dpd_relax','pass_aa_top4mb_relax'))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 66: si_i_o_repeat_wl_e30_3 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 30)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.085173))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 67: si_i_o_repeat_4 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) >= 3)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 68: si_i_o_repeat_wl_e30_4 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 2 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 45)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (a.rv_whitelist_identifier = 'WL_EVER30')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.10180))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
                ) THEN 'Approved'
                /* Reaching here means NO Sicreva rule fired. Fall back to the
                   app-level DT and report the FIRST failing check in priority
                   order. These labels are APP-level, so they do not tell you
                   which Sicreva variable blocked the segment.
                   'No_Segment_Match' = passed every app-level check but still
                   matched no segment row. */
                WHEN a.imp_04_equifax_tof         = 0 THEN 'IMP_04_equifax_tof'
                WHEN a.imp_01_not_deceased        = 0 THEN 'IMP_01_not_deceased'
                WHEN a.imp_02_idccr_mfi_score     = 0 THEN 'IMP_02_idccr_mfi_score'
                WHEN a.imp_03_idccr_mfi_overdue   = 0 THEN 'IMP_03_idccr_mfi_overdue'
                WHEN a.imp_05_user_type_repeat    = 0 THEN 'IMP_05_user_type_repeat'
                WHEN a.imp_06_pincode_risk_tag    = 0 THEN 'IMP_06_pincode_risk_tag'
                WHEN a.r1_risk_01_age             = 0 THEN 'RISK_01_age'
                WHEN a.r1_risk_02_loan_max_dpd    = 0 THEN 'RISK_02_loan_max_dpd'
                WHEN a.r1_risk_03_last_emi_dpd    = 0 THEN 'RISK_03_last_emi_dpd'
                WHEN a.r1_risk_04_cp_max_dpd      = 0 THEN 'RISK_04_cp_max_dpd'
                WHEN a.r1_risk_05_digi_cabal      = 0 THEN 'RISK_05_digi_cabal'
                WHEN a.r1_risk_06_digi_cabal_90d  = 0 THEN 'RISK_06_digi_cabal_90d'
                WHEN a.r1_risk_07_digi_overdues   = 0 THEN 'RISK_07_digi_overdues'
                WHEN a.r1_risk_08_cibil_score     = 0 THEN 'RISK_08_cibil_score'
                WHEN a.r1_risk_09_bureau_vintage  = 0 THEN 'RISK_09_bureau_vintage'
                WHEN a.r1_risk_10_months_90dpd    = 0 THEN 'RISK_10_months_90dpd'
                WHEN a.r1_risk_11_live_overdue    = 0 THEN 'RISK_11_live_overdue'
                WHEN a.r1_risk_12_suit_filed      = 0 THEN 'RISK_12_suit_filed'
                WHEN a.r1_risk_13_write_off_amount = 0 THEN 'RISK_13_write_off_amount'
                WHEN a.r1_risk_14_write_off_12m   = 0 THEN 'RISK_14_write_off_12m'
                WHEN a.r1_risk_15_diff_conc_loans = 0 THEN 'RISK_15_diff_conc_loans'
                WHEN a.r1_risk_16_live_non_agri   = 0 THEN 'RISK_16_live_non_agri'
                WHEN a.r1_risk_17_unsec_enq       = 0 THEN 'RISK_17_unsec_enq'
                WHEN a.r1_risk_18_v34_model       = 0 THEN 'RISK_18_v34_model'
                WHEN a.r1_risk_19_blocklist       = 0 THEN 'RISK_19_blocklist'
                WHEN a.r1_risk_20_v43_model       = 0 THEN 'RISK_20_v43_model'
                WHEN a.iop_01_age                 = 0 THEN 'IOP_01_age'
                WHEN a.iop_02_digi_cabal_90d      = 0 THEN 'IOP_02_digi_cabal_90d'
                WHEN a.iop_03_digi_overdues       = 0 THEN 'IOP_03_digi_overdues'
                WHEN a.iop_04_months_90dpd        = 0 THEN 'IOP_04_months_90dpd'
                WHEN a.iop_05_suit_filed          = 0 THEN 'IOP_05_suit_filed'
                WHEN a.iop_06_write_off_12m       = 0 THEN 'IOP_06_write_off_12m'
                WHEN a.iop_07_blocklist           = 0 THEN 'IOP_07_blocklist'
                WHEN a.iop_10_status_active       = 0 THEN 'IOP_10_status_active'
                WHEN a.iop_12_v43_model_range     = 0 THEN 'IOP_12_v43_model_range'
                WHEN a.iop_11_lts_segment         = 0 THEN 'IOP_11_lts_segment'
                ELSE 'No_Segment_Match'
            END
        ELSE '5_DENIED_2'
    END AS app_first_rejection_flag,

    /* ══════════════════════════════════════════════════════════
       app_first_rejection_value — 'var=value' strings (ported from LCD funnel).
       - Flexi/Segment stages: 'variable_name=<value>' for the exact check that fired.
         NULLs render as '<null>'.
       - Equifax stage: same schema, but the value comes from the *bureau* IDCCR data
         (Step 2d) using the LCD bucketing (Check1/Check2/Check3), NOT from
         a.rejection_reason. Falls back to rejection_reason if bureau miss.
       - Pre/Post-Bureau + 5_DENIED_2: surface trimmed rejection_reason.
       - NULL wire values are rendered '<null>' inside the string, so the field is
         never NULL for real declines (approved rows return 'Approved').
       ══════════════════════════════════════════════════════════ */
    CASE
        /* ── Equifax stage: pull the actual triggering bureau variable ── */
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%' THEN
            COALESCE(
                CASE
                    /* Check2 bucket: score >= 10 AND any of (vintage<=2, score<=500, mn90dpd<=2, live_overdue>25k) */
                    WHEN eq.score >= 10
                     AND (eq.vintage <= 2 OR eq.score <= 500 OR eq.mn_since_90dpd <= 2 OR eq.live_overdue > 25000) THEN
                        CASE
                            WHEN eq.mn_since_90dpd <= 2  THEN 'mn_since_90dpd=' || COALESCE(CAST(eq.mn_since_90dpd AS VARCHAR), '<null>')
                            WHEN eq.live_overdue   > 25000 THEN 'live_overdue='  || COALESCE(CAST(eq.live_overdue   AS VARCHAR), '<null>')
                            WHEN eq.score          <= 500 THEN 'score='          || COALESCE(CAST(eq.score          AS VARCHAR), '<null>')
                            WHEN eq.vintage        <= 2   THEN 'vintage='        || COALESCE(CAST(eq.vintage        AS VARCHAR), '<null>')
                        END
                    /* Check1: vintage<=36 AND lowscore-family OR mfi indicators */
                    WHEN eq.vintage <= 36
                     AND (   (eq.score     BETWEEN 300 AND 699)
                          OR (eq.mfi_score BETWEEN 300 AND 699)
                          OR eq.live_overdue >= 15000
                          OR eq.mfi_live_cnt >= 3)
                        THEN 'score='         || COALESCE(CAST(eq.score        AS VARCHAR), '<null>')
                          || ';mfi_score='    || COALESCE(CAST(eq.mfi_score    AS VARCHAR), '<null>')
                          || ';live_overdue=' || COALESCE(CAST(eq.live_overdue AS VARCHAR), '<null>')
                          || ';mfi_live_cnt=' || COALESCE(CAST(eq.mfi_live_cnt AS VARCHAR), '<null>')
                          || ';vintage='      || COALESCE(CAST(eq.vintage      AS VARCHAR), '<null>')
                    /* Check3: mfi_overdue > 10k */
                    WHEN eq.mfi_overdue > 10000
                        THEN 'mfi_overdue=' || COALESCE(CAST(eq.mfi_overdue AS VARCHAR), '<null>')
                END,
                NULLIF(TRIM(a.rejection_reason), ''),
                'NA'
            )
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'
            THEN COALESCE(NULLIF(TRIM(a.rejection_reason), ''), 'NA')
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'
            THEN COALESCE(NULLIF(TRIM(a.rejection_reason), ''), 'NA')
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            CASE
                WHEN a.imp_04_equifax_tof          = 0 THEN 'equifax_tof='                   || COALESCE(CAST(a.rv_equifax_top_of_the_funnel_reject AS VARCHAR), '<null>')
                WHEN a.imp_01_not_deceased         = 0 THEN 'is_deceased='                   || COALESCE(CAST(a.rv_is_deceased                      AS VARCHAR), '<null>')
                WHEN a.imp_02_idccr_mfi_score      = 0 THEN 'idccr_mfi_score='               || COALESCE(CAST(a.rv_idccr_mfi_score                  AS VARCHAR), '<null>')
                WHEN a.imp_03_idccr_mfi_overdue    = 0 THEN 'idccr_mfi_live_loans_overdue_sum=' || COALESCE(CAST(a.rv_idccr_mfi_live_loans_overdue_sum AS VARCHAR), '<null>')
                WHEN a.imp_05_user_type_repeat     = 0 THEN 'common_user_type='              || COALESCE(a.rv_common_user_type, '<null>')
                WHEN a.imp_06_pincode_risk_tag     = 0 THEN 'final_pincode_risk_tag='        || COALESCE(a.rv_final_pincode_risk_tag, '<null>')
                WHEN a.r1_risk_01_age              = 0 THEN 'common_age='                    || COALESCE(CAST(a.rv_common_age                       AS VARCHAR), '<null>')
                WHEN a.r1_risk_02_loan_max_dpd     = 0 THEN 'loan_last_loan_max_dpd='        || COALESCE(CAST(a.rv_loan_last_loan_max_dpd           AS VARCHAR), '<null>')
                WHEN a.r1_risk_03_last_emi_dpd     = 0 THEN 'loan_last_closed_loan_last_emi_dpd=' || COALESCE(CAST(a.rv_loan_last_closed_loan_last_emi_dpd AS VARCHAR), '<null>')
                WHEN a.r1_risk_04_cp_max_dpd       = 0 THEN 'cp_max_dpd='                    || COALESCE(CAST(a.rv_cp_max_dpd                       AS VARCHAR), '<null>')
                WHEN a.r1_risk_05_digi_cabal       = 0 THEN 'digi_cabal_count='              || COALESCE(CAST(a.rv_digi_cabal_count                 AS VARCHAR), '<null>')
                WHEN a.r1_risk_06_digi_cabal_90d   = 0 THEN 'digi_cabal_count_last_90_days=' || COALESCE(CAST(a.rv_digi_cabal_count_last_90_days     AS VARCHAR), '<null>')
                WHEN a.r1_risk_07_digi_overdues    = 0 THEN 'digi_count_loan_overdues_1m='   || COALESCE(CAST(a.rv_digi_count_loan_overdues_1m      AS VARCHAR), '<null>')
                WHEN a.r1_risk_08_cibil_score      = 0 THEN 'bureau_cibil_3_score='          || COALESCE(CAST(a.rv_bureau_cibil_3_score             AS VARCHAR), '<null>')
                WHEN a.r1_risk_09_bureau_vintage   = 0 THEN 'bureau_cibil_3_bureau_vintage=' || COALESCE(CAST(a.rv_bureau_cibil_3_bureau_vintage    AS VARCHAR), '<null>')
                WHEN a.r1_risk_10_months_90dpd     = 0 THEN 'months_since_last_90_dpd='      || COALESCE(CAST(a.rv_months_since_last_90_dpd         AS VARCHAR), '<null>')
                WHEN a.r1_risk_11_live_overdue     = 0 THEN 'live_loans_overdue_amount_noncc='|| COALESCE(CAST(a.rv_live_loans_overdue_amount_noncc AS VARCHAR), '<null>')
                WHEN a.r1_risk_12_suit_filed       = 0 THEN 'no_of_suit_filed='              || COALESCE(CAST(a.rv_no_of_suit_filed                 AS VARCHAR), '<null>')
                WHEN a.r1_risk_13_write_off_amount = 0 THEN 'write_off_amount='              || COALESCE(CAST(a.rv_write_off_amount                 AS VARCHAR), '<null>')
                WHEN a.r1_risk_14_write_off_12m    = 0 THEN 'write_off_past_12months='       || COALESCE(a.rv_write_off_past_12months, '<null>')
                WHEN a.r1_risk_15_diff_conc_loans  = 0 THEN 'diff_conc_loans='               || COALESCE(CAST(a.rv_diff_conc_loans                  AS VARCHAR), '<null>')
                WHEN a.r1_risk_16_live_non_agri    = 0 THEN 'live_non_agri_count='           || COALESCE(CAST(a.rv_live_non_agri_count              AS VARCHAR), '<null>')
                WHEN a.r1_risk_17_unsec_enq        = 0 THEN 'unsecured_enquiries_1m='        || COALESCE(CAST(a.rv_unsecured_enquiries_1m           AS VARCHAR), '<null>')
                WHEN a.r1_risk_18_v34_model        = 0 THEN 'sagemaker_global_v34='          || COALESCE(CAST(a.rv_sagemaker_global_v34             AS VARCHAR), '<null>')
                WHEN a.r1_risk_19_blocklist        = 0 THEN 'users_to_be_blocklisted='       || COALESCE(CAST(a.rv_users_to_be_blocklisted          AS VARCHAR), '<null>')
                WHEN a.r1_risk_20_v43_model        = 0 THEN 'sagemaker_repeat_v43='          || COALESCE(CAST(a.rv_sagemaker_repeat_v43             AS VARCHAR), '<null>')
                WHEN a.iop_01_age                  = 0 THEN 'common_age='                    || COALESCE(CAST(a.rv_common_age                       AS VARCHAR), '<null>')
                WHEN a.iop_02_digi_cabal_90d       = 0 THEN 'digi_cabal_count_last_90_days=' || COALESCE(CAST(a.rv_digi_cabal_count_last_90_days     AS VARCHAR), '<null>')
                WHEN a.iop_03_digi_overdues        = 0 THEN 'digi_count_loan_overdues_1m='   || COALESCE(CAST(a.rv_digi_count_loan_overdues_1m      AS VARCHAR), '<null>')
                WHEN a.iop_04_months_90dpd         = 0 THEN 'months_since_last_90_dpd='      || COALESCE(CAST(a.rv_months_since_last_90_dpd         AS VARCHAR), '<null>')
                WHEN a.iop_05_suit_filed           = 0 THEN 'no_of_suit_filed='              || COALESCE(CAST(a.rv_no_of_suit_filed                 AS VARCHAR), '<null>')
                WHEN a.iop_06_write_off_12m        = 0 THEN 'write_off_past_12months='       || COALESCE(a.rv_write_off_past_12months, '<null>')
                WHEN a.iop_07_blocklist            = 0 THEN 'users_to_be_blocklisted='       || COALESCE(CAST(a.rv_users_to_be_blocklisted          AS VARCHAR), '<null>')
                WHEN a.iop_10_status_active        = 0 THEN 'output_status='                 || COALESCE(a.rv_output_status, '<null>')
                WHEN a.iop_12_v43_model_range      = 0 THEN 'v43_model_band='                || COALESCE(CAST(a.rv_v43_model                        AS VARCHAR), '<null>')
                WHEN a.iop_11_lts_segment          = 0 THEN 'lts_segment_modify='            || COALESCE(CAST(a.rv_lts_segment_modify               AS VARCHAR), '<null>')
                ELSE 'Approved'
            END
        ELSE COALESCE(NULLIF(TRIM(a.rejection_reason), ''), 'NA')
    END AS app_first_rejection_value,

    /* ══════════════════════════════════════════════════════════
       equifax_check (LCD funnel port)
       Exact equifax bucket per 09_equifax_rejection_validation.sql, resolved from
       the bureau IDCCR snapshot (Step 2d). Populated for every row, regardless of
       whether the txn hit equifax; use in tandem with rejection_stage='1.Equifax'
       to drill into equifax declines.
       ══════════════════════════════════════════════════════════ */
    CASE
        WHEN eq.score >= 10
         AND (eq.vintage <= 2 OR eq.score <= 500 OR eq.mn_since_90dpd <= 2 OR eq.live_overdue > 25000) THEN
            CASE
                WHEN eq.mn_since_90dpd <= 2   THEN 'Check2_mn90dpd_le2'
                WHEN eq.live_overdue   > 25000 THEN 'Check2_live_overdue_gt25k'
                WHEN eq.score          <= 500 THEN 'Check2_score_le500'
                WHEN eq.vintage        <= 2   THEN 'Check2_vintage_le2'
            END
        WHEN eq.vintage <= 36
         AND (   (eq.score     BETWEEN 300 AND 699)
              OR (eq.mfi_score BETWEEN 300 AND 699)
              OR eq.live_overdue >= 15000
              OR eq.mfi_live_cnt >= 3)                                        THEN 'Check1_lowscore_lt36mv'
        WHEN eq.mfi_overdue > 10000                                            THEN 'Check3_mfi_overdue_gt10k'
        WHEN eq.score IS NULL OR eq.pan_hash IS NULL                           THEN 'No_bureau_match'
        ELSE 'Would_ACCEPT_per_logic'
    END AS equifax_check,

    /* ══════════════════════════════════════════════════════════
       sub_reason (LCD funnel port) — stage-prefixed drill-down.
         Equifax     -> 'EQ:'    || equifax_check (or rejection_reason fallback)
         Pre_Bureau  -> 'PREB:'  || rejection_reason
         Post_Bureau -> 'POSTB:' || rejection_reason
         Flexi/Seg   -> app_first_rejection_flag (IMP_* / RISK_* / IOP_* / Approved)
       ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'
            THEN 'EQ:' || COALESCE(
                CASE
                    WHEN eq.score >= 10 AND (eq.vintage<=2 OR eq.score<=500 OR eq.mn_since_90dpd<=2 OR eq.live_overdue>25000) THEN
                        CASE
                            WHEN eq.mn_since_90dpd<=2   THEN 'Check2_mn90dpd_le2'
                            WHEN eq.live_overdue>25000  THEN 'Check2_live_overdue_gt25k'
                            WHEN eq.score<=500          THEN 'Check2_score_le500'
                            WHEN eq.vintage<=2          THEN 'Check2_vintage_le2'
                        END
                    WHEN eq.vintage<=36 AND ((eq.score BETWEEN 300 AND 699) OR (eq.mfi_score BETWEEN 300 AND 699)
                                              OR eq.live_overdue>=15000 OR eq.mfi_live_cnt>=3)
                        THEN 'Check1_lowscore_lt36mv'
                    WHEN eq.mfi_overdue>10000 THEN 'Check3_mfi_overdue_gt10k'
                    WHEN eq.score IS NULL OR eq.pan_hash IS NULL THEN 'No_bureau_match'
                    ELSE 'Would_ACCEPT_per_logic'
                END,
                NULLIF(TRIM(a.rejection_reason), ''),
                '<blank>'
            )
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'
            THEN 'PREB:' || COALESCE(NULLIF(TRIM(a.rejection_reason), ''), '<blank>')
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'
            THEN 'POSTB:' || COALESCE(NULLIF(TRIM(a.rejection_reason), ''), '<blank>')
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            /* Mirrors app_first_rejection_flag: ANY-segment OR + app-DT fallback */
            CASE
                WHEN (
      /* dt 2: si_r_cug_testing */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND (a.rv_user_reference_number = 'IDEP631588977332GZ1P')
      )
     OR       /* dt 6: si_repeat_wl_pq_segment */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND (NVL(a.rv_write_off_amount, 0) <= 0 OR NVL(a.rv_write_off_amount, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (a.rv_whitelist_identifier = 'ABCL_PAPQ')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_wl_reject_users, 0) = 0)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 7: si_wl_low_ir_pf_experiment_segment */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND (NVL(a.rv_write_off_amount, 0) <= 0 OR NVL(a.rv_write_off_amount, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (a.rv_whitelist_identifier = 'CA_POOL_PR_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 8: si_new_repeat_strategy_ultra_power_36m_hemi */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 725)
                     AND (NVL(a.rv_experiment_identifier, '') = 'verified_sal_high_credits_lowrisk' OR NVL(a.rv_experiment_identifier, '') = 'AA_Seg')
                     AND (NVL(a.rv_f2_emi_cap, 0) >= 12000)                                          /* NEW DT col 53: the only check that separates _hemi */
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 9: si_new_repeat_strategy_ultra_power_36m_exp */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 725)
                     AND (NVL(a.rv_experiment_identifier, '') = 'verified_sal_high_credits_lowrisk' OR NVL(a.rv_experiment_identifier, '') = 'AA_Seg')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 10: si_new_repeat_strategy_ultra_power_24m_hemi */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'WL_RPT_CA31')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) = 24)
                     AND (NVL(a.rv_f2_emi_cap, 0) >= 12000)                                          /* NEW DT col 53: the only check that separates _hemi */
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 11: si_new_repeat_strategy_wl_ultra_power_scr_upg */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'WL_RPT_CA31')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) = 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 12: si_lt_repeat_wl_24m_ca_lpf_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 13: si_lt_repeat_wl_24m_lowpricing_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 14: si_lt_repeat_wl_24m_ca_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 15: si_lt_repeat_wl_24m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 0)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 16: si_lt_repeat_wl_24m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 1)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 17: si_new_repeat_strategy_ultra_power_24m_hemi */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 2 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 720)
                     AND (NVL(a.rv_experiment_identifier, '') IN ('Exp_cash_flow_seg', 'Exp_bureau_seg', 'verified_sal_high_credits_lowrisk', 'AA_Seg'))
                     AND (NVL(a.rv_f2_emi_cap, 0) >= 12000)                                          /* NEW DT col 53: the only check that separates _hemi */
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 18: si_new_repeat_strategy_ultra_power_24m_exp */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 2 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (NVL(a.rv_idccr_score, 0) >= 720)
                     AND (NVL(a.rv_experiment_identifier, '') IN ('Exp_cash_flow_seg', 'Exp_bureau_seg', 'verified_sal_high_credits_lowrisk', 'AA_Seg'))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 19: si_new_repeat_strategy_ultra_power_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 24)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 20: si_new_repeat_strategy_ultra_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 21: si_new_repeat_strategy_ultra_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 18)
                     AND (UPPER(NVL(a.rv_offer_request_recompute_reason,'')) = 'ELIGIBLE_FOR_OFFER_UPGRADE')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 22: si_new_repeat_strategy_ultra_power_pbt_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_profile_based_tenure, 0) >= 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 24: si_new_repeat_strategy_wl_power_scr_upg */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'WL_RPT_CA31')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 18)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 25: si_lt_repeat_wl_18m_ca_lpf_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 26: si_lt_repeat_wl_18m_lowpricing_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 27: si_lt_repeat_wl_18m_ca_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 28: si_lt_repeat_wl_18m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 0)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 29: si_lt_repeat_wl_18m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 1)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 30: si_new_repeat_strategy_power_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (a.rv_modified_preclosure_days > 90 OR a.rv_modified_preclosure_days IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_final_emi, 0) >= 5500)
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 1 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 18)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 31: si_new_repeat_strategy_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 5 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 18)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 32: si_new_repeat_strategy_power_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 2000 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 4 OR NVL(a.rv_loan_last_loan_max_dpd, 0) IS NULL)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 3)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_idccr_score, 0) >= 700)
                     AND (NVL(a.rv_v43_location_based_tenure, 0) >= 12)
                     AND (UPPER(NVL(a.rv_offer_request_recompute_reason,'')) = 'ELIGIBLE_FOR_OFFER_UPGRADE')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 33: si_new_repeat_strategy_power_pbt_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (NVL(a.rv_profile_based_tenure, 0) >= 18)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 35: si_lt_repeat_wl_12m_ca_lpf_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 36: si_lt_repeat_wl_12m_lowpricing_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 37: si_lt_repeat_wl_12m_ca_wl */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 38: si_lt_repeat_wl_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 0)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 39: si_lt_repeat_wl_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_low_propensity_low_leverage_flag, 0) = 1)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 40: si_new_repeat_strategy_best_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 1 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 41: si_new_repeat_strategy_best_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 1 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 42: si_new_repeat_strategy_best_aascr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'HR1')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_experiment_identifier, '') = 'AA_Seg')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 43: si_new_repeat_strategy_best_pbt_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (NVL(a.rv_profile_based_tenure, 0) >= 12)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 44: si_lt_repeat_ca_lpf_wl_good_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 45: si_lt_repeat_lowpricing_wl_good_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 46: si_lt_repeat_ca_wl_good_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 47: si_lt_repeat_wl_good_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 48: si_new_repeat_strategy_good_12m */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 9)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 49: si_lt_repeat_ca_lpf_wl_standard_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'STOCK_POOL_PF_REDUCED')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 50: si_lt_repeat_lowpricing_wl_standard_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (a.rv_whitelist_identifier = 'NACH_STUCK_USERS')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 51: si_lt_repeat_ca_wl_standard_12m_lp */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 52: si_lt_repeat_wl_standard_12m */
      (   LOWER(NVL(CAST(a.rv_common_is_whitelisted AS VARCHAR),'false')) = 'true'
                     AND LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) <= 5 OR NVL(a.rv_loan_last_closed_loan_last_emi_dpd, 0) IS NULL)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 53: si_new_repeat_strategy_standard_12m */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_seg_final_input_tenure_v43, 0) >= 6)
                     AND (a.rv_conc_adj_max_emi_cap >= 2200 OR a.rv_conc_adj_max_emi_cap IS NULL)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 57: si_new_repeat_strategy_best_scr_upg */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 2 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.07711690))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_lts_segment_modify, 0) = 24)
                     AND (UPPER(NVL(a.rv_offer_request_recompute_reason,'')) = 'ELIGIBLE_FOR_OFFER_UPGRADE')
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 58: si_i_o_repeat_24m */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 2 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.07711690))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass')
                     AND (NVL(a.rv_lts_segment_modify, 0) = 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 59: si_i_o_repeat_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) = 24)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 60: si_i_o_repeat_wl_e30_1 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 24 AND 59
                     AND (NVL(a.rv_digi_multi_platform_cabal_count, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 3 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) >= 12 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 0 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 15)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'LR' OR UPPER(NVL(a.rv_final_pincode_risk_tag,'')) = 'MR')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.0467364))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 61: si_i_o_repeat_2 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.09941131))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) >= 6)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
              /* AUDIT FIX 2026-08-28: dt_table.csv line 61 - the 2nd si_i_o_repeat_2 row, previously
                 absent. Tighter v43 cut, and NO months_0dpd / prev_tenure / lts_segment_modify gates. */
     OR       /* dt 62: si_i_o_repeat_2 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.06721260))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) IN ('pass','pass_top5mb_relax','pass_top2mb_dpd_relax','pass_aa_top4mb_relax'))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 63: si_i_o_repeat_wl_e30_2 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 0 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 6 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 15)
                     AND (NVL(a.rv_uan_hit_non_salaried_unemp_last_1_yr, 0) != 1)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_cross_platform_ongoing_lt, 0) = 0)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.058347))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 64: si_i_o_repeat_3 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.09941131))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) >= 6)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
              /* AUDIT FIX 2026-08-28: dt_table.csv line 64 - the 2nd si_i_o_repeat_3 row, previously
                 absent. Same v43 cut as its twin but NO prev_tenure / lts_segment_modify gates. */
     OR       /* dt 65: si_i_o_repeat_3 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND ((COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) < 0.09941131))
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) IN ('pass','pass_top5mb_relax','pass_top2mb_dpd_relax','pass_aa_top4mb_relax'))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 66: si_i_o_repeat_wl_e30_3 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_emi_bounce_count_1m, 0) <= 1 OR NVL(a.rv_digi_emi_bounce_count_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_legal_notice_sms_count, 0) <= 0 OR NVL(a.rv_digi_legal_notice_sms_count, 0) IS NULL)
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 0 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_digi_loan_overdues_sum_1m, 0) <= 0 OR NVL(a.rv_digi_loan_overdues_sum_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 1 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 30)
                     AND (NVL(a.rv_shield_rejection_flag, 0) = 0)
                     AND (NVL(a.rv_shield_android_version_800_810_flag, 0) = 0)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (NVL(a.rv_live_loans_overdue_amount, 0) <= 2000 OR NVL(a.rv_live_loans_overdue_amount, 0) IS NULL)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.085173))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 67: si_i_o_repeat_4 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top5mb_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_top2mb_dpd_relax' OR LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_aa_top4mb_relax')
                     AND (NVL(a.rv_lts_segment_modify, 0) >= 3)
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
     OR       /* dt 68: si_i_o_repeat_wl_e30_4 */
      (   LOWER(NVL(a.rv_output_status,'')) = 'active'
                     AND a.rv_common_age BETWEEN 21 AND 59
                     AND (NVL(a.rv_digi_count_loan_overdues_1m, 0) <= 2 OR NVL(a.rv_digi_count_loan_overdues_1m, 0) IS NULL)
                     AND (NVL(a.rv_months_since_last_0_dpd, 999) > 0 OR NVL(a.rv_months_since_last_0_dpd, 999) = -1)
                     AND (NVL(a.rv_months_since_last_90_dpd, 999) > 3 OR NVL(a.rv_months_since_last_90_dpd, 999) = -1)
                     AND (NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) <= 1 OR NVL(a.rv_digi_multi_platform_cabal_count_last_90_days, 0) IS NULL)
                     AND (NVL(a.rv_no_of_suit_filed, 0) <= 0 OR NVL(a.rv_no_of_suit_filed, 0) IS NULL)
                     AND LOWER(NVL(a.rv_write_off_past_12months,'false')) = 'false'
                     AND (NVL(a.rv_loan_last_loan_max_dpd, 0) <= 45)
                     AND (NVL(a.rv_users_to_be_blocklisted, 0) != 1)
                     AND (NVL(a.rv_common_previous_loan_tenure, 0) >= 1)
                     AND (a.rv_whitelist_identifier = 'WL_EVER30')
                     AND (LOWER(NVL(a.rv_important_checks,'')) = 'pass')
                     AND (LOWER(NVL(a.rv_risk_check_flag,'')) = 'pass_e30')
                     AND (NVL(a.rv_idccr_score, 0) >= 680)
                     AND ((a.rv_sagemaker_global_v41 > 0 AND a.rv_sagemaker_global_v41 <= 0.10180))
                     AND (a.rv_loan_combined_ongoing_loans_count_onbook < 2 OR a.rv_loan_combined_ongoing_loans_count_onbook IS NULL)
      )
                ) THEN 'Approved'
                WHEN a.imp_04_equifax_tof          = 0 THEN 'IMP_04_equifax_tof'
                WHEN a.imp_01_not_deceased         = 0 THEN 'IMP_01_not_deceased'
                WHEN a.imp_02_idccr_mfi_score      = 0 THEN 'IMP_02_idccr_mfi_score'
                WHEN a.imp_03_idccr_mfi_overdue    = 0 THEN 'IMP_03_idccr_mfi_overdue'
                WHEN a.imp_05_user_type_repeat     = 0 THEN 'IMP_05_user_type_repeat'
                WHEN a.imp_06_pincode_risk_tag     = 0 THEN 'IMP_06_pincode_risk_tag'
                WHEN a.r1_risk_01_age              = 0 THEN 'RISK_01_age'
                WHEN a.r1_risk_02_loan_max_dpd     = 0 THEN 'RISK_02_loan_max_dpd'
                WHEN a.r1_risk_03_last_emi_dpd     = 0 THEN 'RISK_03_last_emi_dpd'
                WHEN a.r1_risk_04_cp_max_dpd       = 0 THEN 'RISK_04_cp_max_dpd'
                WHEN a.r1_risk_05_digi_cabal       = 0 THEN 'RISK_05_digi_cabal'
                WHEN a.r1_risk_06_digi_cabal_90d   = 0 THEN 'RISK_06_digi_cabal_90d'
                WHEN a.r1_risk_07_digi_overdues    = 0 THEN 'RISK_07_digi_overdues'
                WHEN a.r1_risk_08_cibil_score      = 0 THEN 'RISK_08_cibil_score'
                WHEN a.r1_risk_09_bureau_vintage   = 0 THEN 'RISK_09_bureau_vintage'
                WHEN a.r1_risk_10_months_90dpd     = 0 THEN 'RISK_10_months_90dpd'
                WHEN a.r1_risk_11_live_overdue     = 0 THEN 'RISK_11_live_overdue'
                WHEN a.r1_risk_12_suit_filed       = 0 THEN 'RISK_12_suit_filed'
                WHEN a.r1_risk_13_write_off_amount = 0 THEN 'RISK_13_write_off_amount'
                WHEN a.r1_risk_14_write_off_12m    = 0 THEN 'RISK_14_write_off_12m'
                WHEN a.r1_risk_15_diff_conc_loans  = 0 THEN 'RISK_15_diff_conc_loans'
                WHEN a.r1_risk_16_live_non_agri    = 0 THEN 'RISK_16_live_non_agri'
                WHEN a.r1_risk_17_unsec_enq        = 0 THEN 'RISK_17_unsec_enq'
                WHEN a.r1_risk_18_v34_model        = 0 THEN 'RISK_18_v34_model'
                WHEN a.r1_risk_19_blocklist        = 0 THEN 'RISK_19_blocklist'
                WHEN a.r1_risk_20_v43_model        = 0 THEN 'RISK_20_v43_model'
                WHEN a.iop_01_age                  = 0 THEN 'IOP_01_age'
                WHEN a.iop_02_digi_cabal_90d       = 0 THEN 'IOP_02_digi_cabal_90d'
                WHEN a.iop_03_digi_overdues        = 0 THEN 'IOP_03_digi_overdues'
                WHEN a.iop_04_months_90dpd         = 0 THEN 'IOP_04_months_90dpd'
                WHEN a.iop_05_suit_filed           = 0 THEN 'IOP_05_suit_filed'
                WHEN a.iop_06_write_off_12m        = 0 THEN 'IOP_06_write_off_12m'
                WHEN a.iop_07_blocklist            = 0 THEN 'IOP_07_blocklist'
                WHEN a.iop_10_status_active        = 0 THEN 'IOP_10_status_active'
                WHEN a.iop_12_v43_model_range      = 0 THEN 'IOP_12_v43_model_range'
                WHEN a.iop_11_lts_segment          = 0 THEN 'IOP_11_lts_segment'
                ELSE 'No_Segment_Match'
            END
        ELSE '5_DENIED_2'
    END AS sub_reason,

    /* ── v43 score tracing ── */
    a.rv_sagemaker_repeat_v43                               AS v43_fat_score,
    v43_src.v43_sagemaker_score                             AS v43_app_score,
    auto_sc.auto_model_score                                AS v43_auto_score,
    auto_sc.auto_v43_band                                   AS v43_auto_band,

    COALESCE(
        a.rv_sagemaker_repeat_v43,
        v43_src.v43_sagemaker_score,
        TRY_CAST(auto_sc.auto_model_score AS FLOAT)
    )                                                       AS rv_sagemaker_repeat_v43_a,

    a.rv_v43_model                                          AS v43_model_band,

    CASE
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) IS NULL
          OR COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0          THEN 100
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.04583898 THEN 1
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513 THEN 2
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.06721260 THEN 3
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.07711690 THEN 4
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910 THEN 5
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.09941131 THEN 6
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.11359497 THEN 7
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.13267719 THEN 8
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.16511013 THEN 9
        WHEN COALESCE(a.rv_sagemaker_repeat_v43,
                      v43_src.v43_sagemaker_score,
                      TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 1          THEN 10
        ELSE 100
    END                                                     AS v43_model_band_adj,

    /* ══════════════════════════════════════════════════════════
       PLAIN ENGLISH - THESE ARE THE USEFUL "WHY" COLUMNS.

       Each *_waterfall column answers: "if this customer was aiming at this
       product family, what happened?"

         'Approved'   -> they satisfied AT LEAST ONE rule of the family.
                         Rules are tested in dt_table (1).csv order.
         'FAIL_<var>' -> they satisfied none. The family's LAST DT rule is then
                         the segment of record, and its checks are walked in DT
                         COLUMN order; the first one that fails is reported.

       Rebuilt 2026-08-31 against dt_table (1).csv:
         * segment order and check order are generated from the DT, not hand-kept;
         * the three *_aast_upg rules were removed from every family;
         * ultra_power gains the three _hemi rules (dt 8, 10, 17);
         * every rule gating finbox_variables.status == 'Inactive' was removed
           (dt 1/3/4/5/55/56) - for best that is digifail_lrc and lowts_lrc.

       The "col N" tags are 1-based column indexes into dt_table (1).csv.
    ══════════════════════════════════════════════════════════ */
    /* ══════════════════════════════════════════════════════════
       ultra_power_waterfall -- 10 segments, dt 8/9/10/11/17/18/19/20/21/22

       Approved  = the customer satisfies ANY ONE of these 10 rules.
       Otherwise = dt 22 (si_new_repeat_strategy_ultra_power_pbt_upg), the LAST rule of this family in DT
                   order, becomes the segment for failure analysis, and its checks
                   are walked in DT column order to name the first that failed.
       Rule order and check order below are generated from dt_table (1).csv.
    ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'             THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'     THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                        THEN '3_POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            CASE
                WHEN (   /* dt 8: si_new_repeat_strategy_ultra_power_36m_hemi */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_725 = 1
                       AND a.seg_exp_36m_alt = 1
                       AND a.seg_f2_emi_cap_12000 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 9: si_new_repeat_strategy_ultra_power_36m_exp */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_725 = 1
                       AND a.seg_exp_36m_alt = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 10: si_new_repeat_strategy_ultra_power_24m_hemi */
                            a.seg_is_whitelisted = 1
                       AND a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_whitelist_wl_rpt_ca31 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_eq24 = 1
                       AND a.seg_f2_emi_cap_12000 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 11: si_new_repeat_strategy_wl_ultra_power_scr_upg */
                            a.seg_is_whitelisted = 1
                       AND a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_whitelist_wl_rpt_ca31 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_eq24 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 17: si_new_repeat_strategy_ultra_power_24m_hemi */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt2 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_720 = 1
                       AND a.seg_exp_24m_alt = 1
                       AND a.seg_f2_emi_cap_12000 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 18: si_new_repeat_strategy_ultra_power_24m_exp */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt2 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_720 = 1
                       AND a.seg_exp_24m_alt = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 19: si_new_repeat_strategy_ultra_power_1 */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_0 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge24 = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 20: si_new_repeat_strategy_ultra_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge24 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 21: si_new_repeat_strategy_ultra_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge18 = 1
                       AND a.seg_recompute_upg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 22: si_new_repeat_strategy_ultra_power_pbt_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge18 = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_profile_tenure_ge24 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                THEN 'Approved'

                /* ── Failure cascade: dt 22 si_new_repeat_strategy_ultra_power_pbt_upg — the LAST rule of this
                   family in DT order, walked in DT COLUMN order. Reached only when
                   every rule above failed. ── */
                WHEN a.seg_status_active            = 0 THEN 'IOP_10_status_active'                     /* col 2  finbox_variables.status */
                WHEN a.seg_age_24_59                = 0 THEN 'RISK_02_age_24_59'                        /* col 4  input.common_age */
                WHEN a.seg_multi_cabal_5            = 0 THEN 'RISK_14_multi_cabal_5'                    /* col 5  input.digi_multi_platform_cabal_count */
                WHEN a.seg_preclosure_gt90          = 0 THEN 'IOP_02_preclosure_days'                   /* col 6  finbox_variables.modified_preclosure_days */
                WHEN a.seg_emi_bounce_1             = 0 THEN 'RISK_22_emi_bounce_1'                     /* col 7  input.digi_emi_bounce_count_1m */
                WHEN a.seg_legal_notice_0           = 0 THEN 'RISK_20_legal_notice'                     /* col 8  input.digi_legal_notice_sms_count */
                WHEN a.seg_digi_overdues_0          = 0 THEN 'RISK_16_digi_overdues_0'                  /* col 9  input.digi_count_loan_overdues_1m */
                WHEN a.seg_loan_overdues_sum_0      = 0 THEN 'RISK_18_loan_overdues_sum_0'              /* col 10 input.digi_loan_overdues_sum_1m */
                WHEN a.seg_months_0dpd_gt3          = 0 THEN 'RISK_09_months_0dpd_gt3'                  /* col 11 input.bureau_cibil_3_months_since_last_0_dpd */
                WHEN a.seg_months_90dpd_ge12        = 0 THEN 'RISK_08_months_90dpd_ge12'                /* col 12 input.bureau_cibil_3_months_since_last_90_dpd */
                WHEN a.seg_multi_cabal90d_0         = 0 THEN 'RISK_15_multi_cabal90d_0'                 /* col 14 input.digi_multi_platform_cabal_count_last_90_days */
                WHEN a.seg_suit_filed_0             = 0 THEN 'IMP_06_suit_filed'                        /* col 15 input.bureau_cibil_3_no_of_suit_filed */
                WHEN a.seg_writeoff_12m_false       = 0 THEN 'IMP_05_writeoff_12m'                      /* col 16 input.bureau_cibil_3_write_off_past_12months */
                WHEN a.seg_final_emi_5500           = 0 THEN 'IOP_03_final_emi'                         /* col 17 repeat_offer_variable.final_emi */
                WHEN a.seg_loan_max_dpd_1           = 0 THEN 'RISK_04_loan_max_dpd_1'                   /* col 19 input.loan_last_loan_max_dpd */
                WHEN a.seg_uan_hit_pass             = 0 THEN 'IMP_07_uan_hit'                           /* col 20 finbox_variables.uan_hit_non_salaried_unemp_last_1_yr */
                WHEN a.seg_last_emi_dpd_1           = 0 THEN 'RISK_06_last_emi_dpd_1'                   /* col 21 input.loan_last_closed_loan_last_emi_dpd */
                WHEN a.seg_shield_rej_pass          = 0 THEN 'IMP_08_shield_rejection'                  /* col 23 finbox_variables.shield_rejection_flag */
                WHEN a.seg_shield_android_pass      = 0 THEN 'IMP_09_shield_android'                    /* col 24 finbox_variables.shield_android_version_800_810_flag */
                WHEN a.seg_blocklist_pass           = 0 THEN 'IMP_02_blocklist'                         /* col 25 finbox_variables.users_to_be_blocklisted */
                WHEN a.seg_prev_tenure_ge1          = 0 THEN 'IOP_01_prev_tenure'                       /* col 26 finbox_variables.common_previous_loan_tenure */
                WHEN a.seg_cross_lt_0               = 0 THEN 'RISK_11_cross_platform_lt'                /* col 27 finbox_variables.cross_platform_ongoing_lt */
                WHEN a.seg_live_overdue_2000        = 0 THEN 'RISK_10_live_overdue_2000'                /* col 28 input.bureau_cibil_3_live_loans_overdue_amount */
                WHEN a.seg_important_checks_pass    = 0 THEN 'IMP_03_important_checks'                  /* col 38 finbox_variables.important_checks */
                WHEN a.seg_risk_check_pass          = 0 THEN 'RISK_03_risk_check'                       /* col 40 finbox_variables.risk_check_flag */
                WHEN a.seg_tenure_ge18              = 0 THEN 'IOP_11_tenure_ge18'                       /* col 41 repeat_offer_variable.seg_final_input_tenure_v43 */
                WHEN a.seg_idccr_700                = 0 THEN 'IOP_05_idccr_700'                         /* col 44 input.idccr_score */
                WHEN a.seg_profile_tenure_ge24      = 0 THEN 'IOP_15_profile_tenure_ge24'               /* col 49 offer_computation_variables.profile_based_tenure.Output */
                WHEN a.seg_combined_onbook_lt2      = 0 THEN 'IMP_11_combined_onbook_lt2'               /* col 54 new_finbox_variables.loan_combined_ongoing_loans_count_onbook */
                ELSE 'FAIL_other'
            END
        ELSE '5_DENIED_2'
    END AS ultra_power_waterfall,

    /* ══════════════════════════════════════════════════════════
       ultra_power_waterfall_scrupg -- same 10 Approved segments as
       ultra_power_waterfall above (dt 8/9/10/11/17/18/19/20/21/22, UNCHANGED).

       Otherwise = dt 20 (si_new_repeat_strategy_ultra_power_scr_upg), the
                   family's plain _scr_upg rule, is the benchmark segment
                   INSTEAD OF dt 22 (the family's last-in-DT-order rule), and
                   its 28 checks are walked in DT COLUMN order to name the
                   first that failed.
    ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'             THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'     THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                        THEN '3_POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            CASE
                WHEN (   /* dt 8: si_new_repeat_strategy_ultra_power_36m_hemi */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_725 = 1
                       AND a.seg_exp_36m_alt = 1
                       AND a.seg_f2_emi_cap_12000 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 9: si_new_repeat_strategy_ultra_power_36m_exp */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_725 = 1
                       AND a.seg_exp_36m_alt = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 10: si_new_repeat_strategy_ultra_power_24m_hemi */
                            a.seg_is_whitelisted = 1
                       AND a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_whitelist_wl_rpt_ca31 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_eq24 = 1
                       AND a.seg_f2_emi_cap_12000 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 11: si_new_repeat_strategy_wl_ultra_power_scr_upg */
                            a.seg_is_whitelisted = 1
                       AND a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_whitelist_wl_rpt_ca31 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.05716513
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_eq24 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 17: si_new_repeat_strategy_ultra_power_24m_hemi */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt2 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_720 = 1
                       AND a.seg_exp_24m_alt = 1
                       AND a.seg_f2_emi_cap_12000 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 18: si_new_repeat_strategy_ultra_power_24m_exp */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt2 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_idccr_720 = 1
                       AND a.seg_exp_24m_alt = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 19: si_new_repeat_strategy_ultra_power_1 */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_0 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge24 = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 20: si_new_repeat_strategy_ultra_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge24 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 21: si_new_repeat_strategy_ultra_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge18 = 1
                       AND a.seg_recompute_upg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 22: si_new_repeat_strategy_ultra_power_pbt_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge18 = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_profile_tenure_ge24 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                THEN 'Approved'

                /* ── Failure cascade: dt 20 si_new_repeat_strategy_ultra_power_scr_upg
                   THIS IS THE ONE THING THIS COLUMN CHANGES vs ultra_power_waterfall
                   above. Production walks dt 22 (the family's LAST rule in DT order).
                   Here the benchmark is the family's plain _scr_upg rule instead,
                   walked in DT COLUMN order. Reached only when every rule above
                   failed. ── */
                WHEN a.seg_status_active            = 0 THEN 'IOP_10_status_active'                     /* col 2  finbox_variables.status */
                WHEN a.seg_age_24_59                = 0 THEN 'RISK_02_age_24_59'                        /* col 4  input.common_age */
                WHEN a.seg_multi_cabal_5            = 0 THEN 'RISK_14_multi_cabal_5'                    /* col 5  input.digi_multi_platform_cabal_count */
                WHEN a.seg_emi_bounce_1             = 0 THEN 'RISK_22_emi_bounce_1'                     /* col 7  input.digi_emi_bounce_count_1m */
                WHEN a.seg_legal_notice_0           = 0 THEN 'RISK_20_legal_notice'                     /* col 8  input.digi_legal_notice_sms_count */
                WHEN a.seg_digi_overdues_1          = 0 THEN 'RISK_17_digi_overdues_1'                  /* col 9  input.digi_count_loan_overdues_1m */
                WHEN a.seg_loan_overdues_sum_2000   = 0 THEN 'RISK_19_loan_overdues_sum_2000'           /* col 10 input.digi_loan_overdues_sum_1m */
                WHEN a.seg_months_0dpd_gt1          = 0 THEN 'RISK_09_months_0dpd_gt1'                  /* col 11 input.bureau_cibil_3_months_since_last_0_dpd */
                WHEN a.seg_months_90dpd_ge12        = 0 THEN 'RISK_08_months_90dpd_ge12'                /* col 12 input.bureau_cibil_3_months_since_last_90_dpd */
                WHEN a.seg_multi_cabal90d_0         = 0 THEN 'RISK_15_multi_cabal90d_0'                 /* col 14 input.digi_multi_platform_cabal_count_last_90_days */
                WHEN a.seg_suit_filed_0             = 0 THEN 'IMP_06_suit_filed'                        /* col 15 input.bureau_cibil_3_no_of_suit_filed */
                WHEN a.seg_writeoff_12m_false       = 0 THEN 'IMP_05_writeoff_12m'                      /* col 16 input.bureau_cibil_3_write_off_past_12months */
                WHEN a.seg_loan_max_dpd_4           = 0 THEN 'RISK_05_loan_max_dpd_4'                   /* col 19 input.loan_last_loan_max_dpd */
                WHEN a.seg_uan_hit_pass             = 0 THEN 'IMP_07_uan_hit'                           /* col 20 finbox_variables.uan_hit_non_salaried_unemp_last_1_yr */
                WHEN a.seg_last_emi_dpd_1           = 0 THEN 'RISK_06_last_emi_dpd_1'                   /* col 21 input.loan_last_closed_loan_last_emi_dpd */
                WHEN a.seg_shield_rej_pass          = 0 THEN 'IMP_08_shield_rejection'                  /* col 23 finbox_variables.shield_rejection_flag */
                WHEN a.seg_shield_android_pass      = 0 THEN 'IMP_09_shield_android'                    /* col 24 finbox_variables.shield_android_version_800_810_flag */
                WHEN a.seg_blocklist_pass           = 0 THEN 'IMP_02_blocklist'                         /* col 25 finbox_variables.users_to_be_blocklisted */
                WHEN a.seg_prev_tenure_ge1          = 0 THEN 'IOP_01_prev_tenure'                       /* col 26 finbox_variables.common_previous_loan_tenure */
                WHEN a.seg_live_overdue_2000        = 0 THEN 'RISK_10_live_overdue_2000'                /* col 28 input.bureau_cibil_3_live_loans_overdue_amount */
                WHEN a.seg_important_checks_pass    = 0 THEN 'IMP_03_important_checks'                  /* col 38 finbox_variables.important_checks */
                WHEN COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) IS NULL
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0.08767910
                    THEN 'RISK_23_v43_score'                                            /* col 39 */
                WHEN a.seg_risk_check_pass          = 0 THEN 'RISK_03_risk_check'                       /* col 40 finbox_variables.risk_check_flag */
                WHEN a.seg_tenure_ge3               = 0 THEN 'IOP_08_tenure_ge3'                        /* col 41 repeat_offer_variable.seg_final_input_tenure_v43 */
                WHEN a.seg_conc_adj_emi_pass        = 0 THEN 'IOP_04_conc_adj_emi_cap'                  /* col 42 finbox_variables.conc_adj_max_emi_cap */
                WHEN a.seg_idccr_700                = 0 THEN 'IOP_05_idccr_700'                         /* col 44 input.idccr_score */
                WHEN a.seg_loc_tenure_ge24          = 0 THEN 'IOP_13_loc_tenure_ge24'                   /* col 47 finbox_variables.v43_location_based_tenure */
                WHEN a.seg_combined_onbook_lt2      = 0 THEN 'IMP_11_combined_onbook_lt2'               /* col 54 new_finbox_variables.loan_combined_ongoing_loans_count_onbook */
                ELSE 'FAIL_other'
            END
        ELSE '5_DENIED_2'
    END AS ultra_power_waterfall_scrupg,

    /* ══════════════════════════════════════════════════════════
       power_waterfall -- 5 segments, dt 24/30/31/32/33

       Approved  = the customer satisfies ANY ONE of these 5 rules.
       Otherwise = dt 33 (si_new_repeat_strategy_power_pbt_upg), the LAST rule of this family in DT
                   order, becomes the segment for failure analysis, and its checks
                   are walked in DT column order to name the first that failed.
       Rule order and check order below are generated from dt_table (1).csv.
    ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'             THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'     THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                        THEN '3_POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            CASE
                WHEN (   /* dt 24: si_new_repeat_strategy_wl_power_scr_upg */
                            a.seg_is_whitelisted = 1
                       AND a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_whitelist_wl_rpt_ca31 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge18 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 30: si_new_repeat_strategy_power_1 */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge18 = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 31: si_new_repeat_strategy_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge18 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 32: si_new_repeat_strategy_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge12 = 1
                       AND a.seg_recompute_upg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 33: si_new_repeat_strategy_power_pbt_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge12 = 1
                       AND a.seg_profile_tenure_ge18 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                THEN 'Approved'

                /* ── Failure cascade: dt 33 si_new_repeat_strategy_power_pbt_upg — the LAST rule of this
                   family in DT order, walked in DT COLUMN order. Reached only when
                   every rule above failed. ── */
                WHEN a.seg_status_active            = 0 THEN 'IOP_10_status_active'                     /* col 2  finbox_variables.status */
                WHEN a.seg_age_21_59                = 0 THEN 'RISK_02_age_21_59'                        /* col 4  input.common_age */
                WHEN a.seg_emi_bounce_0             = 0 THEN 'RISK_21_emi_bounce_0'                     /* col 7  input.digi_emi_bounce_count_1m */
                WHEN a.seg_legal_notice_0           = 0 THEN 'RISK_20_legal_notice'                     /* col 8  input.digi_legal_notice_sms_count */
                WHEN a.seg_digi_overdues_0          = 0 THEN 'RISK_16_digi_overdues_0'                  /* col 9  input.digi_count_loan_overdues_1m */
                WHEN a.seg_loan_overdues_sum_0      = 0 THEN 'RISK_18_loan_overdues_sum_0'              /* col 10 input.digi_loan_overdues_sum_1m */
                WHEN a.seg_months_0dpd_gt1          = 0 THEN 'RISK_09_months_0dpd_gt1'                  /* col 11 input.bureau_cibil_3_months_since_last_0_dpd */
                WHEN a.seg_months_90dpd_gt6         = 0 THEN 'RISK_08_months_90dpd_gt6'                 /* col 12 input.bureau_cibil_3_months_since_last_90_dpd */
                WHEN a.seg_multi_cabal90d_1         = 0 THEN 'RISK_15_multi_cabal90d_1'                 /* col 14 input.digi_multi_platform_cabal_count_last_90_days */
                WHEN a.seg_suit_filed_0             = 0 THEN 'IMP_06_suit_filed'                        /* col 15 input.bureau_cibil_3_no_of_suit_filed */
                WHEN a.seg_writeoff_12m_false       = 0 THEN 'IMP_05_writeoff_12m'                      /* col 16 input.bureau_cibil_3_write_off_past_12months */
                WHEN a.seg_uan_hit_pass             = 0 THEN 'IMP_07_uan_hit'                           /* col 20 finbox_variables.uan_hit_non_salaried_unemp_last_1_yr */
                WHEN a.seg_last_emi_dpd_1           = 0 THEN 'RISK_06_last_emi_dpd_1'                   /* col 21 input.loan_last_closed_loan_last_emi_dpd */
                WHEN a.seg_shield_rej_pass          = 0 THEN 'IMP_08_shield_rejection'                  /* col 23 finbox_variables.shield_rejection_flag */
                WHEN a.seg_shield_android_pass      = 0 THEN 'IMP_09_shield_android'                    /* col 24 finbox_variables.shield_android_version_800_810_flag */
                WHEN a.seg_blocklist_pass           = 0 THEN 'IMP_02_blocklist'                         /* col 25 finbox_variables.users_to_be_blocklisted */
                WHEN a.seg_prev_tenure_ge1          = 0 THEN 'IOP_01_prev_tenure'                       /* col 26 finbox_variables.common_previous_loan_tenure */
                WHEN a.seg_cross_lt_0               = 0 THEN 'RISK_11_cross_platform_lt'                /* col 27 finbox_variables.cross_platform_ongoing_lt */
                WHEN a.seg_live_overdue_2000        = 0 THEN 'RISK_10_live_overdue_2000'                /* col 28 input.bureau_cibil_3_live_loans_overdue_amount */
                WHEN a.seg_important_checks_pass    = 0 THEN 'IMP_03_important_checks'                  /* col 38 finbox_variables.important_checks */
                WHEN a.seg_risk_check_pass          = 0 THEN 'RISK_03_risk_check'                       /* col 40 finbox_variables.risk_check_flag */
                WHEN a.seg_tenure_ge12              = 0 THEN 'IOP_10_tenure_ge12'                       /* col 41 repeat_offer_variable.seg_final_input_tenure_v43 */
                WHEN a.seg_profile_tenure_ge18      = 0 THEN 'IOP_15_profile_tenure_ge18'               /* col 49 offer_computation_variables.profile_based_tenure.Output */
                WHEN a.seg_combined_onbook_lt2      = 0 THEN 'IMP_11_combined_onbook_lt2'               /* col 54 new_finbox_variables.loan_combined_ongoing_loans_count_onbook */
                ELSE 'FAIL_other'
            END
        ELSE '5_DENIED_2'
    END AS power_waterfall,

    /* ══════════════════════════════════════════════════════════
       power_waterfall_scrupg -- same 5 Approved segments as power_waterfall
       above (dt 24/30/31/32/33, UNCHANGED).

       Otherwise = dt 31 (si_new_repeat_strategy_power_scr_upg), the family's
                   plain _scr_upg rule, is the benchmark segment INSTEAD OF
                   dt 33 (the family's last-in-DT-order rule), and its 28
                   checks are walked in DT COLUMN order to name the first
                   that failed.
    ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'             THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'     THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                        THEN '3_POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            CASE
                WHEN (   /* dt 24: si_new_repeat_strategy_wl_power_scr_upg */
                            a.seg_is_whitelisted = 1
                       AND a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_whitelist_wl_rpt_ca31 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge18 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 30: si_new_repeat_strategy_power_1 */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_preclosure_gt90 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt3 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_final_emi_5500 = 1
                       AND a.seg_loan_max_dpd_1 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge18 = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 31: si_new_repeat_strategy_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_5 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge18 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 32: si_new_repeat_strategy_power_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_24_59 = 1
                       AND a.seg_multi_cabal_1 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_2000 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_ge12 = 1
                       AND a.seg_multi_cabal90d_0 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_loan_max_dpd_4 = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.0672126
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge3 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_idccr_700 = 1
                       AND a.seg_loc_tenure_ge12 = 1
                       AND a.seg_recompute_upg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 33: si_new_repeat_strategy_power_pbt_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge12 = 1
                       AND a.seg_profile_tenure_ge18 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                THEN 'Approved'

                /* ── Failure cascade: dt 31 si_new_repeat_strategy_power_scr_upg
                   THIS IS THE ONE THING THIS COLUMN CHANGES vs power_waterfall
                   above. Production walks dt 33 (the family's LAST rule in DT order).
                   Here the benchmark is the family's plain _scr_upg rule instead,
                   walked in DT COLUMN order. Reached only when every rule above
                   failed. ── */
                WHEN a.seg_status_active            = 0 THEN 'IOP_10_status_active'                     /* col 2  finbox_variables.status */
                WHEN a.seg_age_24_59                = 0 THEN 'RISK_02_age_24_59'                        /* col 4  input.common_age */
                WHEN a.seg_multi_cabal_5            = 0 THEN 'RISK_14_multi_cabal_5'                    /* col 5  input.digi_multi_platform_cabal_count */
                WHEN a.seg_emi_bounce_1             = 0 THEN 'RISK_22_emi_bounce_1'                     /* col 7  input.digi_emi_bounce_count_1m */
                WHEN a.seg_legal_notice_0           = 0 THEN 'RISK_20_legal_notice'                     /* col 8  input.digi_legal_notice_sms_count */
                WHEN a.seg_digi_overdues_1          = 0 THEN 'RISK_17_digi_overdues_1'                  /* col 9  input.digi_count_loan_overdues_1m */
                WHEN a.seg_loan_overdues_sum_2000   = 0 THEN 'RISK_19_loan_overdues_sum_2000'           /* col 10 input.digi_loan_overdues_sum_1m */
                WHEN a.seg_months_0dpd_gt1          = 0 THEN 'RISK_09_months_0dpd_gt1'                  /* col 11 input.bureau_cibil_3_months_since_last_0_dpd */
                WHEN a.seg_months_90dpd_ge12        = 0 THEN 'RISK_08_months_90dpd_ge12'                /* col 12 input.bureau_cibil_3_months_since_last_90_dpd */
                WHEN a.seg_multi_cabal90d_0         = 0 THEN 'RISK_15_multi_cabal90d_0'                 /* col 14 input.digi_multi_platform_cabal_count_last_90_days */
                WHEN a.seg_suit_filed_0             = 0 THEN 'IMP_06_suit_filed'                        /* col 15 input.bureau_cibil_3_no_of_suit_filed */
                WHEN a.seg_writeoff_12m_false       = 0 THEN 'IMP_05_writeoff_12m'                      /* col 16 input.bureau_cibil_3_write_off_past_12months */
                WHEN a.seg_loan_max_dpd_4           = 0 THEN 'RISK_05_loan_max_dpd_4'                   /* col 19 input.loan_last_loan_max_dpd */
                WHEN a.seg_uan_hit_pass             = 0 THEN 'IMP_07_uan_hit'                           /* col 20 finbox_variables.uan_hit_non_salaried_unemp_last_1_yr */
                WHEN a.seg_last_emi_dpd_1           = 0 THEN 'RISK_06_last_emi_dpd_1'                   /* col 21 input.loan_last_closed_loan_last_emi_dpd */
                WHEN a.seg_shield_rej_pass          = 0 THEN 'IMP_08_shield_rejection'                  /* col 23 finbox_variables.shield_rejection_flag */
                WHEN a.seg_shield_android_pass      = 0 THEN 'IMP_09_shield_android'                    /* col 24 finbox_variables.shield_android_version_800_810_flag */
                WHEN a.seg_blocklist_pass           = 0 THEN 'IMP_02_blocklist'                         /* col 25 finbox_variables.users_to_be_blocklisted */
                WHEN a.seg_prev_tenure_ge1          = 0 THEN 'IOP_01_prev_tenure'                       /* col 26 finbox_variables.common_previous_loan_tenure */
                WHEN a.seg_live_overdue_2000        = 0 THEN 'RISK_10_live_overdue_2000'                /* col 28 input.bureau_cibil_3_live_loans_overdue_amount */
                WHEN a.seg_important_checks_pass    = 0 THEN 'IMP_03_important_checks'                  /* col 38 finbox_variables.important_checks */
                WHEN COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) IS NULL
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0.08767910
                    THEN 'RISK_23_v43_score'                                            /* col 39 */
                WHEN a.seg_risk_check_pass          = 0 THEN 'RISK_03_risk_check'                       /* col 40 finbox_variables.risk_check_flag */
                WHEN a.seg_tenure_ge3               = 0 THEN 'IOP_08_tenure_ge3'                        /* col 41 repeat_offer_variable.seg_final_input_tenure_v43 */
                WHEN a.seg_conc_adj_emi_pass        = 0 THEN 'IOP_04_conc_adj_emi_cap'                  /* col 42 finbox_variables.conc_adj_max_emi_cap */
                WHEN a.seg_idccr_700                = 0 THEN 'IOP_05_idccr_700'                         /* col 44 input.idccr_score */
                WHEN a.seg_loc_tenure_ge18          = 0 THEN 'IOP_13_loc_tenure_ge18'                   /* col 47 finbox_variables.v43_location_based_tenure */
                WHEN a.seg_combined_onbook_lt2      = 0 THEN 'IMP_11_combined_onbook_lt2'               /* col 54 new_finbox_variables.loan_combined_ongoing_loans_count_onbook */
                ELSE 'FAIL_other'
            END
        ELSE '5_DENIED_2'
    END AS power_waterfall_scrupg,

    /* ══════════════════════════════════════════════════════════
       best_waterfall -- 5 segments, dt 40/41/42/43/57

       Approved  = the customer satisfies ANY ONE of these 5 rules.
       Otherwise = dt 57 (si_new_repeat_strategy_best_scr_upg), the LAST rule of this family in DT
                   order, becomes the segment for failure analysis, and its checks
                   are walked in DT column order to name the first that failed.
       Rule order and check order below are generated from dt_table (1).csv.
    ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'             THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'     THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                        THEN '3_POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            CASE
                WHEN (   /* dt 40: si_new_repeat_strategy_best_1 */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge12 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 41: si_new_repeat_strategy_best_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_5 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 42: si_new_repeat_strategy_best_aascr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_5 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_exp_aa_seg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 43: si_new_repeat_strategy_best_pbt_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt3 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_profile_tenure_ge12 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 57: si_new_repeat_strategy_best_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_digi_overdues_2 = 1
                       AND a.seg_months_0dpd_gt0 = 1
                       AND a.seg_months_90dpd_gt3 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_pincode_lr_mr = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.07711690
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_lts_modify_24 = 1
                       AND a.seg_recompute_upg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                THEN 'Approved'

                /* ── Failure cascade: dt 57 si_new_repeat_strategy_best_scr_upg — the LAST rule of this
                   family in DT order, walked in DT COLUMN order. Reached only when
                   every rule above failed. ── */
                WHEN a.seg_status_active            = 0 THEN 'IOP_10_status_active'                     /* col 2  finbox_variables.status */
                WHEN a.seg_age_21_59                = 0 THEN 'RISK_02_age_21_59'                        /* col 4  input.common_age */
                WHEN a.seg_digi_overdues_2          = 0 THEN 'RISK_17_digi_overdues_2'                  /* col 9  input.digi_count_loan_overdues_1m */
                WHEN a.seg_months_0dpd_gt0          = 0 THEN 'RISK_09_months_0dpd_gt0'                  /* col 11 input.bureau_cibil_3_months_since_last_0_dpd */
                WHEN a.seg_months_90dpd_gt3         = 0 THEN 'RISK_08_months_90dpd_gt3'                 /* col 12 input.bureau_cibil_3_months_since_last_90_dpd */
                WHEN a.seg_multi_cabal90d_1         = 0 THEN 'RISK_15_multi_cabal90d_1'                 /* col 14 input.digi_multi_platform_cabal_count_last_90_days */
                WHEN a.seg_suit_filed_0             = 0 THEN 'IMP_06_suit_filed'                        /* col 15 input.bureau_cibil_3_no_of_suit_filed */
                WHEN a.seg_writeoff_12m_false       = 0 THEN 'IMP_05_writeoff_12m'                      /* col 16 input.bureau_cibil_3_write_off_past_12months */
                WHEN a.seg_blocklist_pass           = 0 THEN 'IMP_02_blocklist'                         /* col 25 finbox_variables.users_to_be_blocklisted */
                WHEN a.seg_prev_tenure_ge1          = 0 THEN 'IOP_01_prev_tenure'                       /* col 26 finbox_variables.common_previous_loan_tenure */
                WHEN a.seg_pincode_lr_mr            = 0 THEN 'IMP_10_pincode_lr_mr'                     /* col 37 finbox_variables.final_pincode_risk_tag */
                WHEN a.seg_important_checks_pass    = 0 THEN 'IMP_03_important_checks'                  /* col 38 finbox_variables.important_checks */
                WHEN COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) IS NULL
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0.07711690
                    THEN 'RISK_23_v43_score'                                            /* col 39 */
                WHEN a.seg_risk_check_pass          = 0 THEN 'RISK_03_risk_check'                       /* col 40 finbox_variables.risk_check_flag */
                WHEN a.seg_lts_modify_24            = 0 THEN 'IOP_17_lts_modify_24'                     /* col 43 repeat_offer_variable.lts_segment_modify */
                WHEN a.seg_recompute_upg            = 0 THEN 'IOP_14_recompute_upg_required'            /* col 52 input.offer_request_recompute_reason */
                WHEN a.seg_combined_onbook_lt2      = 0 THEN 'IMP_11_combined_onbook_lt2'               /* col 54 new_finbox_variables.loan_combined_ongoing_loans_count_onbook */
                ELSE 'FAIL_other'
            END
        ELSE '5_DENIED_2'
    END AS best_waterfall,

    /* ══════════════════════════════════════════════════════════
       best_waterfall_scrupg -- same 5 Approved segments as best_waterfall
       above (dt 40/41/42/43/57, UNCHANGED).

       Otherwise = dt 41 (si_new_repeat_strategy_best_scr_upg), the family's
                   plain _scr_upg rule, is the benchmark segment INSTEAD OF
                   dt 57 (the family's last-in-DT-order rule), and its 23
                   checks are walked in DT COLUMN order to name the first
                   that failed.
    ══════════════════════════════════════════════════════════ */
    CASE
        WHEN LOWER(NVL(a.rejection_reason, '')) LIKE '%equifax%'             THEN '1.Equifax'
        WHEN a.module IS NULL OR UPPER(NVL(a.module, '')) = 'PRE_BUREAU'     THEN '1.Pre_Bureau'
        WHEN UPPER(NVL(a.module, '')) = 'POST_BUREAU'                        THEN '3_POST_BUREAU'
        WHEN UPPER(NVL(a.module, '')) IN ('FLEXI_OFFER','SEGMENT','FLEXI','OFFER')
          THEN
            CASE
                WHEN (   /* dt 40: si_new_repeat_strategy_best_1 */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_0 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_1 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_cross_lt_0 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge12 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 41: si_new_repeat_strategy_best_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_1 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_5 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.08767910
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 42: si_new_repeat_strategy_best_aascr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt6 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_uan_hit_pass = 1
                       AND a.seg_last_emi_dpd_5 = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_pincode_lr_mr_hr1 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_exp_aa_seg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 43: si_new_repeat_strategy_best_pbt_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_emi_bounce_1 = 1
                       AND a.seg_legal_notice_0 = 1
                       AND a.seg_digi_overdues_0 = 1
                       AND a.seg_loan_overdues_sum_0 = 1
                       AND a.seg_months_0dpd_gt1 = 1
                       AND a.seg_months_90dpd_gt3 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_shield_rej_pass = 1
                       AND a.seg_shield_android_pass = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_live_overdue_2000 = 1
                       AND a.seg_important_checks_pass = 1
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_tenure_ge6 = 1
                       AND a.seg_conc_adj_emi_pass = 1
                       AND a.seg_profile_tenure_ge12 = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                  OR (   /* dt 57: si_new_repeat_strategy_best_scr_upg */
                            a.seg_status_active = 1
                       AND a.seg_age_21_59 = 1
                       AND a.seg_digi_overdues_2 = 1
                       AND a.seg_months_0dpd_gt0 = 1
                       AND a.seg_months_90dpd_gt3 = 1
                       AND a.seg_multi_cabal90d_1 = 1
                       AND a.seg_suit_filed_0 = 1
                       AND a.seg_writeoff_12m_false = 1
                       AND a.seg_blocklist_pass = 1
                       AND a.seg_prev_tenure_ge1 = 1
                       AND a.seg_pincode_lr_mr = 1
                       AND a.seg_important_checks_pass = 1
                       AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0 AND COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0.07711690
                       AND a.seg_risk_check_pass = 1
                       AND a.seg_lts_modify_24 = 1
                       AND a.seg_recompute_upg = 1
                       AND a.seg_combined_onbook_lt2 = 1
                    )
                THEN 'Approved'

                /* ── Failure cascade: dt 41 si_new_repeat_strategy_best_scr_upg
                   THIS IS THE ONE THING THIS COLUMN CHANGES vs best_waterfall
                   above. Production walks dt 57 (the family's LAST rule in DT order).
                   Here the benchmark is the family's plain _scr_upg rule instead,
                   walked in DT COLUMN order. Reached only when every rule above
                   failed. ── */
                WHEN a.seg_status_active            = 0 THEN 'IOP_10_status_active'                     /* col 2  finbox_variables.status */
                WHEN a.seg_age_21_59                = 0 THEN 'RISK_02_age_21_59'                        /* col 4  input.common_age */
                WHEN a.seg_emi_bounce_1             = 0 THEN 'RISK_22_emi_bounce_1'                     /* col 7  input.digi_emi_bounce_count_1m */
                WHEN a.seg_legal_notice_0           = 0 THEN 'RISK_20_legal_notice'                     /* col 8  input.digi_legal_notice_sms_count */
                WHEN a.seg_digi_overdues_1          = 0 THEN 'RISK_17_digi_overdues_1'                  /* col 9  input.digi_count_loan_overdues_1m */
                WHEN a.seg_loan_overdues_sum_0      = 0 THEN 'RISK_18_loan_overdues_sum_0'              /* col 10 input.digi_loan_overdues_sum_1m */
                WHEN a.seg_months_0dpd_gt1          = 0 THEN 'RISK_09_months_0dpd_gt1'                  /* col 11 input.bureau_cibil_3_months_since_last_0_dpd */
                WHEN a.seg_months_90dpd_gt6         = 0 THEN 'RISK_08_months_90dpd_gt6'                 /* col 12 input.bureau_cibil_3_months_since_last_90_dpd */
                WHEN a.seg_multi_cabal90d_1         = 0 THEN 'RISK_15_multi_cabal90d_1'                 /* col 14 input.digi_multi_platform_cabal_count_last_90_days */
                WHEN a.seg_suit_filed_0             = 0 THEN 'IMP_06_suit_filed'                        /* col 15 input.bureau_cibil_3_no_of_suit_filed */
                WHEN a.seg_writeoff_12m_false       = 0 THEN 'IMP_05_writeoff_12m'                      /* col 16 input.bureau_cibil_3_write_off_past_12months */
                WHEN a.seg_uan_hit_pass             = 0 THEN 'IMP_07_uan_hit'                           /* col 20 finbox_variables.uan_hit_non_salaried_unemp_last_1_yr */
                WHEN a.seg_last_emi_dpd_5           = 0 THEN 'RISK_06_last_emi_dpd_5'                   /* col 21 input.loan_last_closed_loan_last_emi_dpd */
                WHEN a.seg_shield_rej_pass          = 0 THEN 'IMP_08_shield_rejection'                  /* col 23 finbox_variables.shield_rejection_flag */
                WHEN a.seg_shield_android_pass      = 0 THEN 'IMP_09_shield_android'                    /* col 24 finbox_variables.shield_android_version_800_810_flag */
                WHEN a.seg_blocklist_pass           = 0 THEN 'IMP_02_blocklist'                         /* col 25 finbox_variables.users_to_be_blocklisted */
                WHEN a.seg_prev_tenure_ge1          = 0 THEN 'IOP_01_prev_tenure'                       /* col 26 finbox_variables.common_previous_loan_tenure */
                WHEN a.seg_live_overdue_2000        = 0 THEN 'RISK_10_live_overdue_2000'                /* col 28 input.bureau_cibil_3_live_loans_overdue_amount */
                WHEN a.seg_pincode_lr_mr_hr1        = 0 THEN 'IMP_10_pincode_lr_mr_hr1'                 /* col 37 finbox_variables.final_pincode_risk_tag */
                WHEN a.seg_important_checks_pass    = 0 THEN 'IMP_03_important_checks'                  /* col 38 finbox_variables.important_checks */
                WHEN COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) IS NULL
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) <= 0
                  OR COALESCE(a.rv_sagemaker_repeat_v43, v43_src.v43_sagemaker_score, TRY_CAST(auto_sc.auto_model_score AS FLOAT)) > 0.08767910
                    THEN 'RISK_23_v43_score'                                            /* col 39 */
                WHEN a.seg_risk_check_pass          = 0 THEN 'RISK_03_risk_check'                       /* col 40 finbox_variables.risk_check_flag */
                WHEN a.seg_combined_onbook_lt2      = 0 THEN 'IMP_11_combined_onbook_lt2'               /* col 54 new_finbox_variables.loan_combined_ongoing_loans_count_onbook */
                ELSE 'FAIL_other'
            END
        ELSE '5_DENIED_2'
    END AS best_waterfall_scrupg,

    /* ── Raw values pass-through ── */
    a.rv_common_age,
    a.rv_loan_last_loan_max_dpd,
    a.rv_loan_last_closed_loan_last_emi_dpd,
    a.rv_cp_max_dpd,
    a.rv_loan_cross_max_dpd,
    a.rv_digi_cabal_count,
    a.rv_digi_cabal_count_last_90_days,
    a.rv_digi_multi_platform_cabal_count,
    a.rv_digi_multi_platform_cabal_count_last_90_days,
    a.rv_digi_count_loan_overdues_1m,
    a.rv_bureau_cibil_3_score,
    a.rv_bureau_cibil_3_bureau_vintage,
    a.rv_months_since_last_90_dpd,
    a.rv_live_loans_overdue_amount_noncc,
    a.rv_no_of_suit_filed,
    a.rv_write_off_amount,
    a.rv_write_off_past_12months,
    a.rv_diff_conc_loans,
    a.rv_live_non_agri_count,
    a.rv_unsecured_enquiries_1m,
    a.rv_sagemaker_global_v34,
    a.rv_users_to_be_blocklisted,
    a.rv_is_deceased,
    a.rv_idccr_mfi_score,
    a.rv_idccr_mfi_live_loans_overdue_sum,
    a.rv_equifax_top_of_the_funnel_reject,
    a.rv_common_user_type,
    a.rv_final_pincode_risk_tag,
    a.rv_fp_mobilehash_panhash,
    a.rv_lts_segment_modify,
    a.rv_v43_model,
    a.rv_important_checks,
    a.rv_risk_check_flag,
    a.rv_output_status,
    a.rv_common_previous_loan_tenure,
    a.rv_live_loans_overdue_amount,
    a.rv_digi_emi_bounce_count_1m,
    a.rv_digi_legal_notice_sms_count,
    a.rv_digi_loan_overdues_sum_1m,
    a.rv_idccr_score,
    a.rv_final_emi,
    a.rv_f2_emi_cap,
    a.rv_seg_final_input_tenure_v43,
    a.rv_modified_preclosure_days,
    a.rv_loan_cross_ongoing_loan_count,
    a.rv_conc_adj_max_emi_cap,
    a.rv_v43_location_based_tenure,
    a.rv_months_since_last_0_dpd,
    a.rv_experiment_identifier,
    a.rv_loan_previous_loan_channel,
    a.rv_loan_combined_ongoing_loans_count_onbook,
    a.rv_offer_request_recompute_reason,
    a.rv_uan_hit_non_salaried_unemp_last_1_yr,
    a.rv_shield_rejection_flag,
    a.rv_shield_android_version_800_810_flag,
    a.rv_cross_platform_ongoing_lt,
    /* derog raw values */
    a.rv_derog_based_category,
    a.rv_derog_based_tenure,
    a.rv_fresh_derog_category,
    a.rv_abcl_derog,
    a.rv_nac_derog,
    a.rv_smfg_derog,
    a.rv_pchfl_derog,
    a.rv_mas_derog,
    a.rv_vcl_derog,
    a.rv_idccr_fresh_derog_rejection,
    a.rv_idccr_repeat_derog_rejection,
    a.rv_lap_derogs_flag,
    a.rv_aa_income                                          AS output_aa_income,
    a.rv_user_gross_monthly_salary                          AS user_gross_monthly_salary,
    /* ── Equifax IDCCR bureau raw values (from Step 2d) ── */
    eq.score          AS eqfx_score,
    eq.vintage        AS eqfx_vintage,
    eq.mn_since_90dpd AS eqfx_mn_since_90dpd,
    eq.live_overdue   AS eqfx_live_overdue,
    eq.mfi_score      AS eqfx_mfi_score,
    eq.mfi_live_cnt   AS eqfx_mfi_live_cnt,
    eq.mfi_overdue    AS eqfx_mfi_overdue

FROM kissht_reports.temp_tables.tmp_c2_flags a

/* ── v43 source 2: Ring sagemaker score table ── */
LEFT JOIN (
    SELECT
        source_reference_number  AS v43_txn_id,
        model_score__repeat_v43  AS v43_sagemaker_score
    FROM RING_SOURCE.DOCUMENT_DB.SAGEMAKER_REPEAT_V43_DATA
    WHERE user_type = 'REPEAT'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY source_reference_number ORDER BY updated_at DESC) = 1
) v43_src ON a.fb_transaction_id = v43_src.v43_txn_id

/* ── v43 source 3: automation_scoring fallback ── */
LEFT JOIN (
    SELECT fb_transaction_id AS auto_txn_id, auto_model_score, auto_v43_band
    FROM kissht_reports.temp_tables.tmp_loanref_mapping_tenure_analysis_c5
) auto_sc ON auto_sc.auto_txn_id = a.fb_transaction_id

/* ── Equifax IDCCR bureau vars (from Step 2d) ── */
LEFT JOIN kissht_reports.temp_tables.tmp_c2_eqfx eq
    ON eq.fb_transaction_id = a.fb_transaction_id
;
